package Discovery::Engine;
use v5.36;
use Cwd         ();
use File::Spec  ();
use JSON::PP    ();
use POSIX       ();
use Time::HiRes ();
use Discovery::Project;

# The one place that starts the tool and reads what it reports.
# Every harness reads the normalized result, so a rewrite of the engine changes this file alone.
# A saboteur is this adapter with one part replaced, and the observation of a run stays the same code.

my @STATUSES     = qw(Killed Survived NoCoverage Timeout CompileError NoVerdict Ignored Pending);
my %STATUS       = ( RuntimeError => 'NoVerdict' );
my @EXITS        = ( 0 .. 6, 125, 129, 130, 143 );
my $JOBS         = 2;
my $DEADLINE     = 120;
my $POLL_SECONDS = 0.01;
my $END_SECONDS  = 5;
my $REPORT       = 'mutation-report';
my %RUNNING;

my %FLAG = (
    jobs           => sub ($value) { return ( '--jobs',           $value ) },
    coverage       => sub ($value) { return ( '--coverage',       $value ) },
    since          => sub ($value) { return ( '--since',          $value ) },
    shard          => sub ($value) { return ( '--shard',          $value ) },
    timeout_floor  => sub ($value) { return ( '--timeout-floor',  $value ) },
    timeout_factor => sub ($value) { return ( '--timeout-factor', $value ) },
    perl           => sub ($value) { return ( '--perl',           $value ) },
    report         => sub ($value) { return ( '--report-dir',     $value ) },
    configuration  => sub ($value) { return ( '--config',         $value ) },
    in_place       => sub ($value) { return $value ? '--in-place' : () },
    cache          => sub ($value) { return $value ? '--cache'    : () },
    equivalence    => sub ($value) { return $value ? ()           : '--no-equivalence' },
    mutants        => sub ($value) {
        return map { ( '--mutant', $_ ) } $value->@*;
    },
    sources => sub ($value) {
        return map { ( '--source', $_ ) } $value->@*;
    },
    tests => sub ($value) {
        return map { ( '--test', $_ ) } $value->@*;
    },
);

# The settings that the adapter keeps for itself.
# `state` names an input outside the project that changed, which the memo has no other way to tell.
my %OWN = map { $_ => 1 } qw(deadline environment during words state poll prepare);

sub new ( $class, %part ) {
    return
      bless { perl => $^X, library => Cwd::abs_path('lib'), command => Cwd::abs_path('bin') . '/mutation', %part },
      $class;
}

sub statuses () {
    return @STATUSES;
}

# The exit statuses that the contract of the command names.
sub exits () {
    return @EXITS;
}

sub with ( $self, %part ) {
    return bless { $self->%*, %part }, ref $self;
}

# A copy whose results pass through the code before any distortion that the adapter already has.
sub before ( $self, $code ) {
    my $later = $self->{distort};
    return $self->with(
        distort => sub ( $run, $settings ) {
            $code->( $run, $settings );
            $later->( $run, $settings ) if $later;
            return;
        }
    );
}

sub arguments ( $self, %settings ) {
    my @unknown = sort grep { !$FLAG{$_} && !$OWN{$_} } keys %settings;
    die "the adapter has no setting named @unknown\n" if @unknown;
    %settings = ( jobs => $JOBS, %settings );
    return ( '--format', 'json', map { $FLAG{$_}->( $settings{$_} ) } sort grep { $FLAG{$_} } keys %settings );
}

sub _slurp ($path) {
    open my $handle, '<:raw', $path or return;
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return defined $text ? $text : q{};
}

# The child becomes the tool, so it changes its own environment and handles for good.
sub _become ( $root, $environment, $files, $command ) {
    my $ready = eval {
        setpgrp 0, 0;
        chdir $root or die "chdir $root: $!\n";
        ## no critic (Variables::RequireLocalizedPunctuationVars)
        for my $name ( keys $environment->%* ) {
            if ( defined $environment->{$name} ) { $ENV{$name} = $environment->{$name} }
            else                                 { delete $ENV{$name} }
        }
        ## use critic
        open STDIN,  '<', '/dev/null'     or die "stdin: $!\n";
        open STDOUT, '>', "$files/stdout" or die "stdout: $!\n";
        open STDERR, '>', "$files/stderr" or die "stderr: $!\n";
        1;
    };
    exec { $command->[0] } $command->@* if $ready;
    POSIX::_exit(127);
    return;
}

# The tool ends its tests when a signal asks it to end, so the request comes before the force.
sub _end ($pid) {
    kill 'TERM', $pid;
    my $deadline = Time::HiRes::time() + $END_SECONDS;
    while ( Time::HiRes::time() < $deadline ) {
        return $? if waitpid( $pid, POSIX::WNOHANG ) == $pid;
        Time::HiRes::sleep($POLL_SECONDS);
    }
    kill 'KILL', -$pid, $pid;
    waitpid $pid, 0;
    return $?;
}

sub _await ( $pid, $limit, $poll, $tick ) {
    while (1) {
        return ( $?,         0 ) if waitpid( $pid, POSIX::WNOHANG ) == $pid;
        return ( _end($pid), 1 ) if Time::HiRes::time() > $limit;
        $tick->();
        Time::HiRes::sleep($poll);
    }
    return;
}

# The processor time of the children that this process has waited for, in seconds.
sub _waited_cpu () {
    my ( undef, undef, $user, $system ) = times;
    return $user + $system;
}

# `prepare` changes the temporary directory before the run, and `during` reads the files of the run while the tool works.
# `cpu` is the processor time of the tool with the tests that it waited for, as the kernel accounts it when the tool ends.
# A sample of the running tool alone went missing under load, and the tests of a waiting member use no processor anyway.
sub execute ( $self, $project, $temporary, %settings ) {
    my $files       = $project->directory('output');
    my $report      = File::Spec->rel2abs( defined $settings{report} ? $settings{report} : $REPORT, $project->root );
    my @words       = $settings{words} ? $settings{words}->@* : ();
    my @command     = ( $self->{perl}, "-I$self->{library}", $self->{command}, @words, $self->arguments(%settings) );
    my %environment = ( TMPDIR => $temporary, ( $settings{environment} || {} )->%* );
    $settings{prepare}->($temporary) if $settings{prepare};
    my $started = Time::HiRes::time();
    my $used    = _waited_cpu();
    my $pid     = fork;
    die "fork: $!"                                              if !defined $pid;
    _become( $project->root, \%environment, $files, \@command ) if !$pid;
    $RUNNING{$pid} = 1;

    my %at   = ( pid => $pid, temporary => $temporary, root => $project->root, stderr => "$files/stderr" );
    my $tick = sub {
        $settings{during}->( \%at ) if $settings{during};
        return;
    };
    my $limit = $started + ( defined $settings{deadline} ? $settings{deadline} : $DEADLINE );
    my ( $status, $hung ) = _await( $pid, $limit, defined $settings{poll} ? $settings{poll} : $POLL_SECONDS, $tick );
    delete $RUNNING{$pid};
    return {
        exit    => $status >> 8,
        signal  => $status & 127,
        hung    => $hung,
        seconds => Time::HiRes::time() - $started,
        cpu     => _waited_cpu() - $used,
        stdout  => scalar _slurp("$files/stdout"),
        stderr  => scalar _slurp("$files/stderr"),
        report  => scalar _slurp("$report/mutation.json"),
    };
}

sub _position ($location) {
    return map { $location->{$_}->@{qw(line column)} } qw(start end);
}

sub normalize ( $self, $raw ) {
    my %run = (
        $raw->%{qw(exit signal hung seconds cpu stdout stderr)},
        reported          => 0,
        mutants           => {},
        status            => {},
        reason            => {},
        by                => {},
        covered           => {},
        counts            => {},
        warnings          => [],
        tests             => {},
        baseline_failures => [],
        reused            => 0,
        interrupted       => undef,
    );
    my $document = defined $raw->{report} ? eval { JSON::PP->new->utf8->decode( $raw->{report} ) } : undef;
    return \%run if ref $document ne 'HASH' || ref $document->{testMutation} ne 'HASH';

    my $facts = $document->{testMutation};
    $run{reported}          = 1;
    $run{warnings}          = [ sort $facts->{warnings}->@* ];
    $run{tests}             = { map { $_->{name} => $_->{duration} } $facts->{tests}->@* };
    $run{baseline_failures} = [ sort $facts->{baselineFailures}->@* ];
    $run{reused}            = $facts->{reused};
    $run{interrupted}       = $facts->{interrupted};
    for my $path ( sort keys $document->{files}->%* ) {
        for my $mutant ( $document->{files}{$path}{mutants}->@* ) {
            my $id = $mutant->{id};
            my ( $line, $column, $end_line, $end_column ) = _position( $mutant->{location} );
            my $status = $STATUS{ $mutant->{status} } || $mutant->{status};
            $run{mutants}{$id} = {
                path        => $path,
                line        => $line,
                column      => $column,
                end_line    => $end_line,
                end_column  => $end_column,
                replacement => $mutant->{replacement},
                mutator     => $mutant->{mutatorName},
            };
            $run{status}{$id}  = $status;
            $run{reason}{$id}  = $mutant->{statusReason};
            $run{by}{$id}      = $mutant->{killedBy} ? $mutant->{killedBy}[0] : undef;
            $run{covered}{$id} = [ sort $mutant->{coveredBy}->@* ];
            $run{counts}{$status}++;
        }
    }
    return \%run;
}

sub _names ( $directory, $pattern ) {
    opendir my $handle, $directory or return;
    my @names = sort grep { $_ ne q{.} && $_ ne q{..} && $_ =~ $pattern } readdir $handle;
    closedir $handle or die "close $directory: $!";
    return @names;
}

sub _left ( $temporary, $root ) {
    return [
        ( map { "$_ in the temporary directory" } _names( $temporary, qr/./ ) ),
        ( map { ".mutation/$_ in the project" } _names( "$root/.mutation", qr/\Arun-/ ) ),
    ];
}

sub _cache_file ($project) {
    return $project->root . '/.mutation/cache.json';
}

# The identifiers of the mutants that the cache of the project holds a record of.
sub cache_ids ( $self, $project ) {
    my $text    = _slurp( _cache_file($project) );
    my $content = defined $text ? eval { JSON::PP->new->utf8->decode($text) } : undef;
    my @ids     = ref $content eq 'HASH' && ref $content->{mutants} eq 'HASH' ? sort keys $content->{mutants}->%* : ();
    return \@ids;
}

# A repeated run answers from the memo when the settings, the files, and the cache are what they were.
sub _key ( $project, $before, %settings ) {
    my %plain = map { $_ => $settings{$_} } grep { !ref $settings{$_} || ref $settings{$_} ne 'CODE' } keys %settings;
    return JSON::PP->new->canonical->encode(
        [ $project->root, \%plain, $before, scalar _slurp( _cache_file($project) ) ] );
}

sub _executed ( $self, $project, $temporary, $before, %settings ) {
    my $memo = $self->{memo} or return $self->execute( $project, $temporary, %settings );
    my $key  = _key( $project, $before, %settings );
    my $file = _cache_file($project);
    if ( !$memo->{$key} ) {
        $memo->{$key} = { raw => $self->execute( $project, $temporary, %settings ), cache => scalar _slurp($file) };
    }
    elsif ( defined $memo->{$key}{cache} ) {
        $project->write( '.mutation/cache.json', $memo->{$key}{cache} );
    }
    return $memo->{$key}{raw};
}

# A run starts with a private temporary directory and without a report, so everything it leaves is its own.
sub run ( $self, $project, %settings ) {
    my $temporary = $project->directory('temporary');
    $project->remove( defined $settings{report} ? $settings{report} : $REPORT );
    my $before = $project->snapshot;
    my %stood  = map { $_ => 1 } _left( $temporary, $project->root )->@*;
    my $raw    = $self->_executed( $project, $temporary, $before, %settings );
    $self->{damage}->( $project, $temporary, \%settings ) if $self->{damage};

    my $run = $self->normalize($raw);
    $run->{left}      = [ grep { !$stood{$_} } _left( $temporary, $project->root )->@* ];
    $run->{changed}   = Discovery::Project::changes( $before, $project->snapshot );
    $run->{processes} = $project->living;
    $project->reap;
    $self->{distort}->( $run, \%settings ) if $self->{distort};
    return $run;
}

# The whole run that the tool gives for the reports of every part of a split run.
sub merge ( $self, $project, $reports, %settings ) {
    return $self->run( $project, %settings, words => [ 'merge', $reports->@* ], report => "$REPORT/merged" );
}

# A harness that a signal ends still runs its END blocks, which end the tool and remove the scratch files.
## no critic (Variables::RequireLocalizedPunctuationVars)
$SIG{HUP}  = sub { exit 129 };
$SIG{INT}  = sub { exit 130 };
$SIG{TERM} = sub { exit 143 };
## use critic

END {
    my $status = $?;
    for my $pid ( keys %RUNNING ) {
        kill 'KILL', -$pid, $pid;
        waitpid $pid, 0;
    }
    $? = $status;    ## no critic (Variables::RequireLocalizedPunctuationVars)
}

1;
