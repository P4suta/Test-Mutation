package Discovery::Faults;
use v5.36;
use Discovery::Check;
use Discovery::Known;
use Discovery::Project;

# Faults that reach the tool while it works: signals at a known moment, a listener that dies, and places it cannot write.
# The tool has no list of phases yet, so a moment is a state of the files that the tool has reached.

my $FILLER_FILES = 1000;
my @AFTER        = qw(I2 I3 I4);

my $SLOW = <<'PERL';
use Known;
sub value { my ( $cell, @arguments ) = @_; return scalar Known->can($cell)->(@arguments) }
select undef, undef, undef, 0.3;
PERL

# The project holds many files, so a copy and its removal last long enough to meet a signal.
# Its one test is slow, so the unmodified run and the run of each mutant last long enough too.
sub bench ( $files = $FILLER_FILES ) {
    my $known = Discovery::Known->new(
        tests => 1,
        cells => [ { body => 'return $x + $y', rows => [ [ 2, 3 ] ], test => 't/a.t' } ],
    );
    my $project = Discovery::Project->new;
    $project->write( 'lib/Known.pm',                        $known->module('Known') );
    $project->write( 't/a.t',                               $known->test_text( 't/a.t', load => $SLOW ) );
    $project->write( sprintf( 'data/filler-%04d.txt', $_ ), "filler $_\n" ) for 1 .. $files;
    return { project => $project, known => $known };
}

sub _exists ($pattern) {
    my @found = glob $pattern;
    return scalar @found;
}

sub _holds ( $path, $pattern ) {
    open my $handle, '<', $path or return 0;
    my $text = do { local $/ = undef; readline $handle };
    close $handle or return 0;
    return defined $text && $text =~ $pattern ? 1 : 0;
}

# The moments of a run, each as a question about the files: the answer turns true when the tool is there.
my %MOMENT = (
    'the copy'                  => sub ($at) { return _exists("$at->{temporary}/mutation-*") },
    'the unmodified run'        => sub ($at) { return _exists("$at->{root}/.mutation/run-*/records/*/*.rec") },
    'the mutants'               => sub ($at) { return _holds( $at->{stderr}, qr/^\[\s*[0-9]+\/[0-9]+\]/m ) },
    'the removal of the copies' => sub ($at) {
        return !_exists("$at->{root}/.mutation/run-*") && _exists("$at->{temporary}/mutation-*");
    },
);

sub moments () {
    my @names = sort keys %MOMENT;
    return @names;
}

sub _found ( $label, $run, @fault ) {
    my %seen =
      map { ( "fault=$label: $_" => 1 ) } Discovery::Check::findings( [ 'fault', @AFTER ], run => $run, @fault );
    my @labelled = sort keys %seen;
    return @labelled;
}

# One signal when the tool reaches the moment.
sub signalled ( $engine, $bench, $signal, $moment ) {
    my $reached = $MOMENT{$moment} or die "no moment is named $moment\n";
    my $sent    = 0;
    my $run     = $engine->run(
        $bench->{project},
        poll   => 0.001,
        during => sub ($at) {
            return if $sent || !$reached->($at);
            $sent = kill $signal, $at->{pid};
            return;
        },
    );
    return ( "the signal $signal never met $moment",                      0 ) if !$sent;
    return ( _found( "$signal during $moment", $run, signal => $signal ), 1 );
}

# A signal during the mutants, and another one when the tool removes its copies after the first.
sub signalled_twice ( $engine, $bench, $signal ) {
    my ( $first, $again ) = ( 0, 0 );
    my $run = $engine->run(
        $bench->{project},
        poll   => 0.001,
        during => sub ($at) {
            if ( !$first ) {
                $first = kill $signal, $at->{pid} if $MOMENT{'the mutants'}->($at);
            }
            elsif ( !$again ) {
                $again = kill $signal, $at->{pid} if $MOMENT{'the removal of the copies'}->($at);
            }
            return;
        },
    );
    return ( "the signal $signal never met the removal of the copies",                            0 ) if !$again;
    return ( _found( "$signal again during the removal of the copies", $run, signal => $signal ), 1 );
}

my $DYING_LISTENER = <<'PERL';
use v5.36;
use Test::Mutation::CLI;
use Test::Mutation::Runner;
my $run = \&Test::Mutation::Runner::run;
{
    no warnings 'redefine';
    *Test::Mutation::Runner::run = sub ( $config, $listener ) {
        return $run->(
            $config,
            sub ( $event, $data ) {
                $listener->( $event, $data );
                die "the listener dies\n" if $event eq $ENV{DISCOVERY_DIES_AT};
                return;
            }
        );
    };
}
exit Test::Mutation::CLI::main(@ARGV);
PERL

# The command with a listener that dies at one event of the run.
sub dying_listener ( $engine, $bench, $event ) {
    my $script = $bench->{project}->scratch . '/dying-listener';
    open my $handle, '>', $script or die "write $script: $!";
    print {$handle} $DYING_LISTENER or die "write $script: $!";
    close $handle                   or die "close $script: $!";
    my $run =
      $engine->with( command => $script )->run( $bench->{project}, environment => { DISCOVERY_DIES_AT => $event } );
    return _found( "a listener that dies at $event", $run, fails => 1 );
}

# A temporary directory that refuses new entries.
sub read_only_temporary ( $engine, $bench ) {
    my $run = $engine->run(
        $bench->{project},
        prepare => sub ($temporary) {
            chmod oct '555', $temporary or die "chmod $temporary: $!";
        }
    );
    return _found( 'a temporary directory without the right to write', $run );
}

sub missing_interpreter ( $engine, $bench ) {
    my $run = $engine->run( $bench->{project}, perl => $bench->{project}->scratch . '/no-such-perl' );
    return _found( 'an interpreter that is no file', $run, fails => 1 );
}

# A file that refuses to be read ends the copy of the project midway.
sub unreadable_file ( $engine, $bench ) {
    my $project = $bench->{project};
    $project->write( 'data/sealed.txt', "sealed\n", mode => 0 );
    my $run = $engine->run($project);
    $project->remove('data/sealed.txt');
    return _found( 'a file without the right to read', $run, fails => 1 );
}

# The cache lives in the work directory of the project, which here refuses new entries.
sub unwritable_cache ( $engine, $bench ) {
    my $project   = $bench->{project};
    my $directory = $project->root . '/.mutation';
    $project->write( '.mutation/cache.json', '{}' );
    chmod oct '555', $directory or die "chmod $directory: $!";
    my $run = $engine->run( $project, cache => 1 );
    chmod oct '755', $directory or die "chmod $directory: $!";
    $project->remove('.mutation');
    return _found( 'a cache directory without the right to write', $run, fails => 1 );
}

# The tests run in copies and write nothing, so a project that refuses new entries is still measured.
sub read_only_project ( $engine, $bench ) {
    my $project = $bench->{project};
    chmod oct '555', $project->root or die 'chmod ' . $project->root . ": $!";
    my $run = $engine->run( $project, report => $project->scratch . '/report' );
    chmod oct '755', $project->root or die 'chmod ' . $project->root . ": $!";
    my %seen = map { ( "fault=a project without the right to write: $_" => 1 ) }
      Discovery::Check::findings( [ 'completes', @AFTER ], run => $run );
    my @labelled = sort keys %seen;
    return @labelled;
}

1;
