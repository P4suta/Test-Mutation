package B::Unresolved;
use v5.36;
use B       ();
use English qw(-no_match_vars);

# Perl compiles a unit as its main program, and this module reports what the compiled code holds.
# `perl -MB::Unresolved=report FILE` prints the report of one file.
# `perl -MB::Unresolved=serve,DIRECTORY,SECONDS -` reads requests from its standard input.
# The server forks a child for each unit, and the child compiles the unit in place of the program of the server.
# Perl reads that program from the standard input, which the child points at the file of the unit.
# The modules that the server holds are loaded in every child, so a unit costs its own compilation alone.

my $SUBROUTINE_LINES = 0x10;
my %job;

sub import ( $class, $verb = undef, @arguments ) {
    return                                                     if !defined $verb;
    return _serve(@arguments)                                  if $verb eq 'serve';
    die "B::Unresolved knows serve and report, and no $verb\n" if $verb ne 'report';
    %job = ( calls => 1 );
    return _compile_only();
}

# Perl records the lines of every named subroutine under this flag, and the walker finds the subroutines of the unit there.
sub _compile_only () {
    $^P = $SUBROUTINE_LINES;    ## no critic (Variables::RequireLocalizedPunctuationVars)
    B::minus_c();
    B::save_BEGINs();
    return;
}

# A child inherits what a buffer holds, so the server reads its requests one character at a time.
sub _line ($requests) {
    my $line = q{};
    while ( sysread $requests, my $character, 1 ) {
        return $line if $character eq "\n";
        $line .= $character;
    }
    return;
}

sub _reply ( $replies, $text ) {
    syswrite $replies, "$text\n" or die "reply: $!\n";
    return;
}

# A module that reads or prints while it loads must reach neither the requests nor the replies.
# The server keeps both on handles of its own, and its standard handles lead nowhere.
sub _private_channels () {
    open my $requests, '<&', \*STDIN     or die "requests: $!\n";
    open my $replies,  '>&', \*STDOUT    or die "replies: $!\n";
    open STDIN,        '<',  '/dev/null' or die "standard input: $!\n";
    open STDOUT,       '>',  '/dev/null' or die "standard output: $!\n";
    return ( $requests, $replies );
}

sub _serve ( $directory, $seconds ) {
    my ( $requests, $replies ) = _private_channels();
    while ( defined( my $line = _line($requests) ) ) {
        my ( $verb, @fields ) = split /\t/, $line, -1;
        if ( $verb eq 'require' ) {
            for my $file (@fields) {
                eval { require $file; 1 } or next;
            }
            _reply( $replies, 'done' );
            next;
        }
        my $pid = fork;
        die "fork: $!\n" if !defined $pid;
        if ( !$pid ) {
            return _become_unit( $directory, @fields ) if $verb eq 'compile';
            _load_unit( $directory, @fields );
        }
        _reply( $replies, _waited( $pid, $seconds ) );
    }

    # Dependencies can install END blocks for their own program while the server preloads them.
    require POSIX;
    POSIX::_exit(0);
    return;
}

# The child loads the unit as a test loads a module, and the result holds one word for the outcome.
# The child leaves without the END blocks of the unit, which belong to a program that ran to its end.
sub _load_unit ( $directory, $path ) {
    open STDOUT, '>', '/dev/null'         or exit 1;
    open STDERR, '>', "$directory/stderr" or exit 1;
    my $loaded = eval { require $path; 1 };
    if ( !$loaded ) {
        print {*STDERR} $@ or exit 1;
    }
    open my $result, '>', "$directory/result" or exit 1;
    print {$result} $loaded ? "loaded\n" : "died\n" or exit 1;
    close $result                                   or exit 1;
    require POSIX;
    POSIX::_exit(0);
    return;
}

sub _waited ( $pid, $seconds ) {
    my $stopped = 0;
    local $SIG{ALRM} = sub { $stopped = 1; kill 'KILL', $pid };
    alarm $seconds;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;
    return $stopped ? 'timeout' : "done\t$status";
}

# The child returns from the import of this module, and perl goes on to compile the unit from the standard input.
sub _become_unit ( $directory, $path, $wants ) {
    open STDIN,  '<', $path               or exit 1;
    open STDOUT, '>', '/dev/null'         or exit 1;
    open STDERR, '>', "$directory/stderr" or exit 1;
    %job = ( ( map { $_ => 1 } split /,/, $wants ), directory => $directory );
    return _compile_only();
}

# The name of the subroutine that a call names, when no code stands behind the name.
sub _missing_target ( $cv, $call ) {
    my $last = $call->first;
    $last = $last->first if $last->name eq 'null' && !${ $last->sibling } && $last->flags & B::OPf_KIDS();
    while ( ${ $last->sibling } ) {
        $last = $last->sibling;
    }
    $last = $last->first if $last->name eq 'null' && $last->flags & B::OPf_KIDS();
    return               if $last->name ne 'gv';
    my $glob = $last->isa('B::PADOP') ? $cv->PADLIST->ARRAYelt(1)->ARRAYelt( $last->padix ) : $last->gv;

    # A subroutine without a glob of its own stands in the operator as a reference, and it has code.
    return if !$glob->isa('B::GV');
    my $code = $glob->CV;
    return if $$code && ( ${ $code->ROOT } || $code->XSUB );
    return $glob->STASH->NAME . q{::} . $glob->NAME;
}

sub _walk ( $cv, $root, $found ) {
    my @pending = ($root);
    while ( my $op = pop @pending ) {
        next if !$$op;
        if ( $op->name eq 'entersub' ) {
            my $name = _missing_target( $cv, $op );
            $found->{$name} = 1 if defined $name;
        }
        next if !( $op->flags & B::OPf_KIDS() );
        my $kid = $op->first;
        while ($$kid) {
            push @pending, $kid;
            $kid = $kid->sibling;
        }
    }
    return;
}

# An anonymous subroutine stands in the pad of the code around it, and a lexical one stands behind its name there.
sub _inner ($cv) {
    my $padlist = $cv->PADLIST;
    return if !$$padlist || !$padlist->isa('B::PADLIST');
    my @values = grep { $_->isa('B::CV') } $padlist->ARRAYelt(1)->ARRAY;
    my @named  = map  { $_->PROTOCV } grep { $_->isa('B::PADNAME') } $padlist->ARRAYelt(0)->ARRAY;
    return @values, grep { $_->isa('B::CV') } @named;
}

sub _code ( $cv, $seen, $found ) {
    my @pending = ($cv);
    while ( my $next = pop @pending ) {
        next if $seen->{$$next}++;
        my $root = $next->ROOT;
        _walk( $next, $root, $found ) if $$root;
        push @pending, _inner($next);
    }
    return;
}

sub _named_subroutines () {
    my $file  = quotemeta $0;
    my @names = grep { $DB::sub{$_} =~ /\A$file:/ } sort keys %DB::sub;    ## no critic (Variables::ProhibitPackageVars)
    no strict 'refs';                                                      ## no critic (TestingAndDebugging::ProhibitNoStrict)
    return map { B::svref_2object( \&{$_} ) } grep { defined &{$_} } @names;
}

sub _unresolved () {
    my ( %seen, %found );
    my $main = B::main_cv();
    _walk( $main, B::main_root(), \%found );
    my $begins = B::begin_av();
    my @blocks = $begins->isa('B::AV') ? grep { $_->FILE eq $0 } $begins->ARRAY : ();
    _code( $_, \%seen, \%found ) for $main, @blocks, _named_subroutines();
    my @names = sort keys %found;
    return @names;
}

# B::Deparse prints to the standard output, as it does under the O module.
sub _print_code ($path) {
    require B::Deparse;
    open STDOUT, '>', $path or die "write $path: $!\n";
    local $OUTPUT_RECORD_SEPARATOR = undef;
    local $LIST_SEPARATOR          = q{ };
    local $OUTPUT_FIELD_SEPARATOR  = q{};
    B::Deparse::compile()->();
    close STDOUT or die "close $path: $!\n";
    return;
}

sub _deliver (@lines) {
    my $directory = $job{directory};
    my $handle    = \*STDOUT;
    if ( defined $directory ) {
        open $handle, '>', "$directory/result" or die "write the result: $!\n";
    }
    print {$handle} map { "$_\n" } @lines or die "write the result: $!\n";
    close $handle                         or die "close the result: $!\n";
    return;
}

sub _report () {
    my @lines;
    push @lines, map { "call\t$_" } _unresolved()    if $job{calls};
    push @lines, map { "loaded\t$_" } sort keys %INC if $job{loaded};

    # B::Deparse dies on some compiled code, and the unit then has a reason in the place of its printed code.
    if ( $job{deparse} && !eval { _print_code("$job{directory}/deparse"); 1 } ) {
        push @lines, "undeparsed\t" . $@ =~ s/\s+/ /gr;
    }
    return _deliver(@lines);
}

# A walker that dies must not turn a sound unit into a refused one, so its failure travels in the result.
sub _checked () {
    return if eval { _report(); 1 };
    return _deliver( "broken\t" . $@ =~ s/\s+/ /gr );
}

# Perl runs this block after a failed compilation too, and the exit status of perl stays the verdict.
CHECK {
    _checked() if %job && ${ B::main_root() };
}

1;
