package Permutl;
use v5.36;
use Types::Standard qw(ArrayRef HashRef InstanceOf Slurpy);
use Type::Params    qw(signature_for);
use Permutl::Config;
use Permutl::Runner;

our $VERSION = '0.001';

my %NOT_A_SETTING = map { $_ => 1 } qw(new from_layers);

sub _config (%settings) {
    my @unknown = sort grep { $NOT_A_SETTING{$_} || !Permutl::Config->can($_) } keys %settings;
    die 'unknown setting: ' . join( ', ', @unknown ) . "\n" if @unknown;
    return Permutl::Config->new(%settings);
}

signature_for run => ( positional => [ Slurpy [HashRef] ], returns => InstanceOf ['Permutl::Result'] );

sub run ($settings) {
    my %settings = $settings->%*;
    my $listener = delete $settings{on_event};
    return Permutl::Runner::run( _config(%settings), $listener ? $listener : sub { } );
}

signature_for mutants => (
    positional => [ Slurpy [HashRef] ],
    returns    => ArrayRef [ InstanceOf ['Permutl::Mutant'] ],
);

sub mutants ($settings) {
    return Permutl::Runner::analyze( _config( $settings->%* ) )->{mutants};
}

1;

__END__

=head1 NAME

Permutl - mutation testing for Perl that leaves the source tree untouched

=head1 SYNOPSIS

    permutl run
    permutl list
    permutl show 4769d125ff17
    permutl exec 4769d125ff17 -- prove -l t/sign.t

    use Permutl;
    my $result = Permutl::run( root => q{.}, jobs => 4 );
    printf "%.1f%%\n", $result->tally->{score};

=head1 DESCRIPTION

Permutl changes one small piece of a source file at a time and runs the tests that reach it.
A test suite that keeps passing has missed the change, and the report shows where.

The source files on disk stay as they are.
Each test process loads a mutated copy through a hook in C<@INC>, so an interrupted run leaves nothing to restore.

The unmodified sources run first through the same hook.
That run times every test and records the lines it reaches, and later each mutant runs the tests that reach its statement.

A mutant ends in one of these states.
C<Killed> means a test failed.
C<Survived> means every test that reached the mutant passed.
C<NoCoverage> means no test loaded the mutated code.
C<Timeout> means a test exceeded its time limit, which the score leaves out.
C<CompileError> means the mutant does not compile.
C<RuntimeError> means a test loaded the original file around the hook.
C<Ignored> means a comment suppressed the mutant, or the mutant compiles to code the run already knows.

The score is the percentage of C<Killed> among C<Killed>, C<Survived>, and C<NoCoverage>.

A mutant that passed every test compiles once more next to the original, and the run compares the two with L<B::Deparse>.
Equal code means no test can tell the two apart, so the mutant leaves the score.

C<permutl run --since origin/main> covers the changed lines, and C<--shard 2/4> covers one of four equal parts.
C<--cache> reuses the results of an earlier run for every mutant whose file and tests are unchanged.
L<Test::Permutl> asserts a score from a test file.

=head1 CONFIGURATION

C<permutl run> works without configuration: it mutates C<lib/**/*.pm> and runs C<t/**/*.t> with C<-Ilib>.
A file named C<permutl.toml> in the project directory changes the defaults.

    jobs = 4
    cache = true

    [source]
    include = ["lib/**/*.pm"]
    exclude = ["lib/Generated/**"]

    [test]
    include = ["t/**/*.t"]
    switches = ["-Ilib"]
    timeout-factor = 4
    timeout-floor = 10
    coverage = "line"

    [mutators]
    profile = "default"
    enable = ["regex-anchor"]
    disable = ["sub-body"]
    equivalence = true

    [report]
    directory = "permutl-report"
    formats = ["terminal", "json", "html"]

    [thresholds]
    high = 80
    low = 60
    break = 70

The C<extended> profile adds mutators for literals, fixed conditions, sort order, range bounds, and patterns.
C<permutl list --profile extended> shows what a profile produces.

A comment suppresses the mutants on its line, and a comment on a line of its own suppresses them until C<## use mutate>.

    my $port = $base + 1;    ## no mutate
    ## no mutate (arithmetic, comparison)
    ...
    ## use mutate

=head1 FUNCTIONS

=head2 run

    my $result = Permutl::run( root => $directory, jobs => 4, on_event => sub ( $event, $data ) { } );

Measures the project and returns a L<Permutl::Result>.
The settings are the attributes of L<Permutl::Config>, and C<on_event> receives the progress events of L<Permutl::Runner>.

=head2 mutants

    my $mutants = Permutl::mutants( root => $directory, profile => 'extended' );

Returns the L<Permutl::Mutant> objects of the project without running a test.

=head1 LIMITS

A file that a test loads by absolute path, and a script that a test runs as a program, run unmutated.
A child process in taint mode ignores C<PERL5OPT> and runs the original code.
The run reports a test that loads a source file around the hook.
Linux and macOS are supported.

=head1 LICENSE

MIT or Apache License 2.0, at your option.

=cut
