package Test::Mutation;
use v5.36;
use Cwd             ();
use Exporter        qw(import);
use Types::Standard qw(ArrayRef Bool HashRef InstanceOf Slurpy);
use Type::Params    qw(signature_for);
use Test::Mutation::Config;
use Test::Mutation::Runner;

our $VERSION = '0.001';
our @EXPORT  = qw(mutation_score_ok);    ## no critic (Modules::ProhibitAutomaticExportation)

my %NOT_A_SETTING = map { $_ => 1 } qw(new from_layers read_file);

sub _config (%settings) {
    my @unknown = sort grep { $NOT_A_SETTING{$_} || !Test::Mutation::Config->can($_) } keys %settings;
    die 'unknown setting: ' . join( ', ', @unknown ) . "\n" if @unknown;
    my $root = delete $settings{root};
    $root = q{.} if !defined $root;
    my $file = "$root/permutl.toml";
    return Test::Mutation::Config->from_layers(
        root     => $root,
        defaults => {},
        file     => -e $file ? Test::Mutation::Config::read_file($file) : {},
        cli      => \%settings,
    );
}

signature_for run => ( positional => [ Slurpy [HashRef] ], returns => InstanceOf ['Test::Mutation::Result'] );

sub run ($settings) {
    my %settings = $settings->%*;
    my $listener = delete $settings{on_event};
    return Test::Mutation::Runner::run( _config(%settings), $listener ? $listener : sub { } );
}

signature_for mutants => (
    positional => [ Slurpy [HashRef] ],
    returns    => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ],
);

sub mutants ($settings) {
    return Test::Mutation::Runner::analyze( _config( $settings->%* ) )->{mutants};
}

signature_for mutation_score_ok => ( positional => [ Slurpy [HashRef] ], returns => Bool );

sub mutation_score_ok ($settings) {
    my %settings = ( root => q{.}, $settings->%* );
    my $minimum  = exists $settings{min}  ? delete $settings{min}  : 100;
    my $name     = exists $settings{name} ? delete $settings{name} : "the mutation score is at least $minimum%";

    # The command and the library run without the modules of a test file.
    require Test::Builder;
    require Test::Mutation::Report::Terminal;
    my $builder = Test::Builder->new;
    my $outer   = defined $ENV{PERMUTL_ROOT} ? Cwd::abs_path( $ENV{PERMUTL_ROOT} ) : undef;
    my $own     = Cwd::abs_path( $settings{root} );
    if ( defined $outer && defined $own && $outer eq $own ) {
        $builder->skip('inside a permutl run');
        return 1;
    }

    my $result  = run(%settings);
    my $score   = $result->tally->{score};
    my $reached = $result->conclusive && defined $score && $score >= $minimum ? 1 : 0;
    $builder->ok( $reached, $name );
    $builder->diag( Test::Mutation::Report::Terminal::render( $result, color => 0 ) ) if !$reached;
    return $reached;
}

1;

__END__

=head1 NAME

Test::Mutation - mutation testing for Perl that never rewrites a source file

=head1 SYNOPSIS

    permutl run
    permutl list
    permutl show 4769d125ff17
    permutl exec 4769d125ff17 -- prove -l t/sign.t
    permutl merge part-1/mutation.json part-2/mutation.json

    use Test::Mutation;
    my $result = Test::Mutation::run( root => q{.}, jobs => 4 );
    printf "%.1f%%\n", $result->tally->{score};

    use Test::More tests => 1;
    use Test::Mutation;
    mutation_score_ok( min => 80 );

=head1 DESCRIPTION

Test::Mutation changes one small piece of a source file at a time and runs the tests that reach it.
A test suite that keeps passing has missed the change, and the report shows where.

The source files on disk stay as they are.
Each test process loads a mutated copy through a hook in C<@INC>, so an interrupted run leaves nothing to restore.

The tests run in copies of the project inside the temporary directory.
A file that a test writes or removes under a mutant changes a copy, and the project stays as it was.
Each mutant starts from the state that the unmodified run left, so no mutant sees what another one left behind.
A copy leaves out C<.git>, the work directory, and the report directory, and it holds C<local> as a link.
C<--in-place> runs the tests in the project itself, for tests that need the repository data.

The unmodified sources run first through the same hook.
That run times every test and records the lines it reaches, and later each mutant runs the tests that reach its statement.

A mutant ends in one of these states.
C<Killed> means a test failed.
C<Survived> means every test that reached the mutant passed.
C<NoCoverage> means no test loaded the mutated code.
C<Timeout> means a test exceeded its time limit and no other test failed, which the score leaves out.
After a timeout the run tries the next test, and the second timeout ends the work on the mutant.
C<CompileError> means the mutant does not compile.
C<RuntimeError> means a test loaded the original file around the hook.
C<Ignored> means a comment suppressed the mutant, or the mutant compiles to code the run already knows.

The score is the percentage of C<Killed> among C<Killed>, C<Survived>, and C<NoCoverage>.

A mutant that no test detected compiles once more next to the original, and the run compares the two with L<B::Deparse>.
That covers a survivor and a mutant that no test reaches.
Equal code means no test can tell the two apart, so the mutant leaves the score.
A mutant in a field or in an C<ADJUST> block skips the comparison, because L<B::Deparse> prints neither.

C<permutl run --since origin/main> covers the changed lines, and C<--shard 2/4> covers one of four equal parts.
C<permutl merge> reads the C<mutation.json> of every part and reports the whole run, with its score and its exit status.
It refuses a set of files that misses a part or mixes two runs.
C<--cache> reuses the results of an earlier run for every mutant whose file and tests are unchanged.
C<mutation_score_ok> asserts a score from a test file.

=head1 CONFIGURATION

C<permutl run> works without configuration: it mutates C<lib/**/*.pm> and runs C<t/**/*.t> with C<-Ilib>.
A file named C<permutl.toml> in the project directory changes the defaults.
A run writes its reports into C<permutl-report>, and C<--cache> keeps its results in C<.permutl>.
Both directories belong in C<.gitignore>.

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
    in-place = false
    link = ["local"]

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
C<permutl mutators> prints the name, the profile, and the description of every mutator, for C<enable> and C<disable>.

A comment suppresses the mutants on its line, and a comment on a line of its own suppresses them until C<## use mutate>.

    my $port = $base + 1;    ## no mutate
    ## no mutate (arithmetic, comparison)
    ...
    ## use mutate

=head1 FUNCTIONS

=head2 run

    my $result = Test::Mutation::run( root => $directory, jobs => 4, on_event => sub ( $event, $data ) { } );

Measures the project and returns a L<Test::Mutation::Result>.
The settings are the attributes of L<Test::Mutation::Config>, and C<on_event> receives the progress events of L<Test::Mutation::Runner>.
C<root> is the working directory when the call leaves it out.
A C<permutl.toml> in the root directory supplies the settings that the call leaves out.

=head2 mutants

    my $mutants = Test::Mutation::mutants( root => $directory, profile => 'extended' );

Returns the L<Test::Mutation::Mutant> objects of the project without running a test.

=head2 mutation_score_ok

    mutation_score_ok( min => 80, name => 'tests detect mutants', jobs => 4, profile => 'extended' );

Runs permutl on the project in the current directory from a test file, which gets the function by loading the module.
Passes when the run is conclusive and the score reaches C<min>, 100 by default.
C<name> names the test, and every other setting goes to C<run>, which also reads C<permutl.toml>.
A failing assertion prints the report with the undetected mutants as diagnostics.
A test file under C<xt/> keeps the measurement out of the tests that permutl itself runs.
Inside a permutl run of the same project the assertion is a skip, so a copy under C<t/> does not start a run for every mutant.

=head1 LIMITS

A file that a test loads by absolute path, and a script that a test runs as a program, run unmutated.
A child process in taint mode ignores C<PERL5OPT> and runs the original code.
The run reports a test that loads a source file around the hook.
A mutant runs with the rights of the tests.
An absolute path, a link that points out of the project, and a linked directory such as C<local> lead a test out of its copy.
With C<--in-place>, a mutant may create, change, or remove a file of the project.
The run then reports such a change and gives no verdict to a mutant that a test broken by the change detected.
C<permutl exec> runs its command in the project itself.
Linux and macOS are supported.

=head1 AUTHOR

Yasunobu Sakashita

=head1 LICENSE

Copyright (c) Yasunobu Sakashita.

MIT or Apache License 2.0, at your option.

=cut
