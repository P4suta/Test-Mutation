package Discovery::Faults;
use v5.36;
use Discovery::Check;
use Discovery::Known;
use Discovery::Project;

# Faults that reach the tool while it works: signals at a known moment, a listener that dies, and places it cannot write.

my $FILLER_FILES = 1000;
my $LARGE_CELLS  = 3000;
my $LARGE_FILES  = 60;
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

# The lines that the tool writes when it has analyzed the sources, passed the unmodified run, and finished a mutant.
my $PASSED   = qr/^The unmodified run passed/m;
my $MEASURED = qr/^discovery-measured-mutant$/m;

# Each deadline marks the next phase that the signal must precede.
my %MOMENT = (
    'the copy' => {
        reached => sub ($at) { return _exists("$at->{temporary}/mutation-*/tree/*/data/filler-*") },
        before  => qr/^discovery-phase baseline$/m,
    },
    'the analysis' => {
        reached => sub ($at) { return _holds( $at->{stderr}, qr/^discovery-phase analyze$/m ) },
        before  => qr/^discovery-phase plan$/m,
    },
    'the unmodified run' =>
      { reached => sub ($at) { return _exists("$at->{temporary}/mutation-*/work/records/*/*.rec") } },
    'the cache digest' => { reached => sub ($at) { return _holds( $at->{stderr}, $PASSED ) }, before => $MEASURED },
    'the mutants'      => { reached => sub ($at) { return _holds( $at->{stderr}, $MEASURED ) } },
    'the removal of the copies' => {
        reached => sub ($at) {
            return _holds( $at->{stderr}, qr/^discovery-phase release$/m ) && _exists("$at->{temporary}/mutation-*");
        }
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

# One signal when the tool reaches the moment, in a run with the given settings.
sub signalled ( $engine, $bench, $signal, $moment, %settings ) {
    my $spec = $MOMENT{$moment} or die "no moment is named $moment\n";
    my $sent = 0;
    my $run  = _observed( $engine, $bench )->run(
        $bench->{project},
        %settings,
        poll   => 0.001,
        during => sub ($at) {
            return if $sent || !$spec->{reached}->($at);
            $sent = kill $signal, $at->{pid};
            return;
        },
    );
    my $late = $spec->{before} && $run->{stderr} =~ $spec->{before};
    return ( "the signal $signal never met $moment",                      0 ) if !$sent || $late;
    return ( _found( "$signal during $moment", $run, signal => $signal ), 1 );
}

# A project whose one large source file keeps the analysis busy for longer than a signal needs to arrive.
sub analysis_bench () {
    my $bench = bench(0);
    my $cells = join q{}, map { "sub cell_$_ { my ( \$x, \$y ) = \@_; return \$x + \$y - $_ }\n" } 1 .. $LARGE_CELLS;
    $bench->{project}->write( 'lib/Large.pm', "package Large;\nuse strict;\nuse warnings;\n${cells}1;\n" );
    return $bench;
}

# A project whose large files beside the tests keep the digests of the cache busy.
sub digest_bench () {
    my $bench = bench(0);
    my $block = 'digest me ' x 100_000;
    $bench->{project}->write( sprintf( 't/data/block-%02d.bin', $_ ), $block . $_ ) for 1 .. $LARGE_FILES;
    return $bench;
}

# A signal during the mutants, and another one when the tool removes its copies after the first.
sub signalled_twice ( $engine, $bench, $signal ) {
    my ( $first, $again ) = ( 0, 0 );
    my $run = _observed( $engine, $bench )->run(
        $bench->{project},
        poll   => 0.001,
        during => sub ($at) {
            if ( !$first ) {
                $first = kill $signal, $at->{pid} if $MOMENT{'the mutants'}{reached}->($at);
            }
            elsif ( !$again ) {
                $again = kill $signal, $at->{pid} if $MOMENT{'the removal of the copies'}{reached}->($at);
            }
            return;
        },
    );
    return ( "the signal $signal never met the removal of the copies",                            0 ) if !$again;
    return ( _found( "$signal again during the removal of the copies", $run, signal => $signal ), 1 );
}

my $LISTENER = <<'PERL';
use v5.36;
use Test::Mutation::CLI;
use Test::Mutation::Runner;
my $run = \&Test::Mutation::Runner::run;
{
    no warnings 'redefine';
    *Test::Mutation::Runner::run = sub ( $config, $listener, @options ) {
        return $run->(
            $config,
            sub ( $event, $data ) {
                $listener->( $event, $data );
                my $name = $event eq 'phase' ? "phase:$data->{name}" : $event;
                print STDERR "discovery-phase $data->{name}\n" if $event eq 'phase';
                print STDERR "discovery-measured-mutant\n" if $event eq 'mutant';
                die "the listener dies\n" if defined $ENV{DISCOVERY_DIES_AT} && $name eq $ENV{DISCOVERY_DIES_AT};
                return;
            },
            @options,
        );
    };
}
exit Test::Mutation::CLI::main(@ARGV);
PERL

sub _observed ( $engine, $bench ) {
    my $script = $bench->{project}->scratch . '/observed-run';
    open my $handle, '>', $script or die "write $script: $!";
    print {$handle} $LISTENER or die "write $script: $!";
    close $handle             or die "close $script: $!";
    return $engine->with( command => $script );
}

sub dying_listener ( $engine, $bench, $event ) {
    my $run = _observed( $engine, $bench )->run( $bench->{project}, environment => { DISCOVERY_DIES_AT => $event } );
    return _found( "a listener that dies at $event", $run, fails => 1, internal => 1 );
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
    my $run =
      $engine->run( $project, report => $project->scratch . '/report', cache_dir => $project->scratch . '/cache' );
    chmod oct '755', $project->root or die 'chmod ' . $project->root . ": $!";
    my %seen = map { ( "fault=a project without the right to write: $_" => 1 ) }
      Discovery::Check::findings( [ 'completes', @AFTER ], run => $run );
    my @labelled = sort keys %seen;
    return @labelled;
}

1;
