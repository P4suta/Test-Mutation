package Judge;
use v5.36;
use Cwd         ();
use File::Spec  ();
use File::Temp  ();
use IO::Select  ();
use POSIX       ();
use Time::HiRes ();

# Perl judges a unit in a process that starts clean, so no symbol of the test process reaches the unit.
# A server holds the modules of a unit and forks a child for each variant, which costs one compilation of the unit.

my $SECONDS    = 20;
my $STOP_POLLS = 400;
my $STOP_PAUSE = 0.005;

sub _switches (%arg) {
    return map { '-I' . Cwd::abs_path($_) } 'xt/lib', ( $arg{include} || [] )->@*;
}

sub _spew ( $path, $bytes ) {
    open my $handle, '>:raw', $path or die "write $path: $!\n";
    print {$handle} $bytes or die "write $path: $!\n";
    close $handle          or die "close $path: $!\n";
    return;
}

sub _slurp ($path) {
    open my $handle, '<:raw', $path or return q{};
    my $bytes = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!\n";
    return defined $bytes ? $bytes : q{};
}

# The child runs perl with its three standard handles on the given files, and a fixed hash order for B::Deparse.
sub _spawn ( $input, $output, $errors, @command ) {
    my $pid = fork;
    die "fork: $!\n" if !defined $pid;
    return $pid      if $pid;
    my $opened = open( STDIN, '<&', $input ) && open( STDOUT, '>&', $output ) && open STDERR, '>&', $errors;
    local @ENV{qw(PERL_HASH_SEED PERL_PERTURB_KEYS)} = ( 0, 0 );
    delete local $ENV{PERL5OPT};
    exec {$^X} $^X, @command if $opened;
    POSIX::_exit(127);
    return;
}

sub _null ($mode) {
    open my $handle, $mode, File::Spec->devnull or die 'open ' . File::Spec->devnull . ": $!\n";
    return $handle;
}

sub start (%arg) {
    my $directory = File::Temp->newdir;
    my $seconds   = defined $arg{timeout} ? $arg{timeout} : $SECONDS;
    pipe my $requests, my $to      or die "pipe: $!\n";
    pipe my $from,     my $replies or die "pipe: $!\n";
    my $pid =
      _spawn( $requests, $replies, _null('>'), _switches(%arg), "-MB::Unresolved=serve,$directory,$seconds", q{-} );
    close $requests or die "close: $!\n";
    close $replies  or die "close: $!\n";

    # The server stops a unit after its own limit, so a longer silence means that the server itself hangs.
    my $patience = defined $arg{patience} ? $arg{patience} : 2 * $seconds + $SECONDS;
    return { pid => $pid, to => $to, from => $from, directory => $directory, patience => $patience };
}

sub _ask ( $judge, @fields ) {
    my $line = join( "\t", @fields ) . "\n";
    syswrite $judge->{to}, $line or die "the judge takes no request: $!\n";
    die "the judge gives no answer\n" if !IO::Select->new( $judge->{from} )->can_read( $judge->{patience} );
    my $reply = q{};
    while ( sysread $judge->{from}, my $character, 1 ) {
        return $reply if $character eq "\n";
        $reply .= $character;
    }
    die "the judge ended\n";
}

sub preload ( $judge, @files ) {
    return _ask( $judge, 'require', @files ) eq 'done' ? 1 : 0;
}

sub _lines ( $text, $kind ) {
    return [ map { /\A\Q$kind\E\t(.*)\z/ ? $1 : () } split /\n/, $text ];
}

sub _verdict ( $sound, $errors, $report, $code ) {
    die "the walker broke: $report\n" if $report =~ /^broken\t/m;
    my ($undeparsed) = _lines( $report, 'undeparsed' )->@*;
    return {
        compiled    => $sound,
        timed_out   => 0,
        diagnostics => $errors,
        calls       => _lines( $report, 'call' ),
        loaded      => _lines( $report, 'loaded' ),
        deparse     => defined $undeparsed ? undef       : $code,
        undeparsed  => defined $undeparsed ? $undeparsed : q{},
    };
}

# Perl compiled the unit when it ended with status zero and said so, whatever the unit printed before.
sub compiled ( $judge, $bytes, @wants ) {
    my $directory = $judge->{directory};
    my %path      = map { $_ => "$directory/$_" } qw(unit stderr result deparse);
    unlink @path{qw(stderr result deparse)};
    _spew( $path{unit}, $bytes );
    my ( $answer, $status ) = split /\t/, _ask( $judge, 'compile', $path{unit}, join q{,}, @wants );
    my $errors = _slurp( $path{stderr} );
    my $sound  = $answer eq 'done' && $status == 0 && $errors =~ s/^- syntax OK\n\z//m ? 1 : 0;
    my $verdict =
      _verdict( $sound, $errors, $sound ? _slurp( $path{result} ) : q{}, $sound ? _slurp( $path{deparse} ) : q{} );
    $verdict->{timed_out} = 1 if $answer eq 'timeout';
    return $verdict;
}

# Perl loaded the unit when `require` gave a true value in a child of the server, before any END block of the unit.
sub loaded ( $judge, $bytes ) {
    my $directory = $judge->{directory};
    unlink "$directory/stderr", "$directory/result";
    _spew( "$directory/unit", $bytes );
    my ( $answer, $status ) = split /\t/, _ask( $judge, 'load', "$directory/unit" );
    my $done = $answer eq 'done' && $status == 0 && _slurp("$directory/result") eq "loaded\n";
    return {
        loaded      => $done                ? 1 : 0,
        timed_out   => $answer eq 'timeout' ? 1 : 0,
        diagnostics => _slurp("$directory/stderr")
    };
}

# The server ends when its requests end, and a server that hangs is ended by force.
# The answer tells whether the server ended on its own and without an error.
sub stop ($judge) {
    close $judge->{to}   or die "close: $!\n";
    close $judge->{from} or die "close: $!\n";
    for my $wait ( 1 .. $STOP_POLLS ) {
        return $? == 0 ? 1 : 0 if waitpid( $judge->{pid}, POSIX::WNOHANG() ) > 0;
        Time::HiRes::sleep($STOP_PAUSE);
    }
    kill 'KILL', $judge->{pid};
    waitpid $judge->{pid}, 0;
    return 0;
}

sub _cold ( $bytes, $switch, %arg ) {
    my $directory = File::Temp->newdir;
    my $unit      = "$directory/unit";
    _spew( $unit, $bytes );
    open my $output, '>', "$directory/stdout" or die "write: $!\n";
    open my $errors, '>', "$directory/stderr" or die "write: $!\n";
    my $pid = _spawn( _null('<'), $output, $errors, _switches(%arg), $switch, $unit );

    # A unit that never ends its compilation has no cold answer, and the caller reads the stop as a refusal.
    local $SIG{ALRM} = sub { kill 'KILL', $pid };
    alarm 2 * $SECONDS;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;
    my $said  = _slurp("$directory/stderr");
    my $sound = $status == 0 && $said =~ s/^\Q$unit\E syntax OK\n\z//m ? 1 : 0;
    return _verdict( $sound, $said, $sound ? _slurp("$directory/stdout") : q{}, q{} );
}

# The answer of `perl -c` for a unit, the reference of the server.
sub reference ( $bytes, %arg ) {
    return _cold( $bytes, '-c', %arg )->{compiled};
}

# The answer of the walker for a unit that perl compiles as a program of its own.
sub reference_calls ( $bytes, %arg ) {
    return _cold( $bytes, '-MB::Unresolved=report', %arg );
}

1;
