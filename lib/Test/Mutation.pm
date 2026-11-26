package Test::Mutation;
use v5.36;
use Cwd             ();
use Exporter        qw(import);
use Types::Standard qw(ArrayRef Bool CodeRef HashRef InstanceOf Maybe Slurpy Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Runner;
use Test::Mutation::Outcome;
use Test::Mutation::Exit;
use Test::Mutation::Settings;

our $VERSION = '0.001';
our @EXPORT  = qw(mutation_score_ok);    ## no critic (Modules::ProhibitAutomaticExportation)

# The arguments of a call: the settings, which the table of the settings checks, and the listener or the words of an assertion.
my $CALL = Slurpy [ HashRef [ Maybe [ Str | ArrayRef [Str] | CodeRef ] ] ];

signature_for run => ( positional => [$CALL], returns => InstanceOf ['Test::Mutation::Result'] );

sub run ($settings) {
    my %settings = $settings->%*;
    my $listener = delete $settings{on_event};
    return Test::Mutation::Runner::run( Test::Mutation::Settings::of_call( \%settings ),
        $listener ? $listener : sub { } );
}

signature_for mutants => ( positional => [$CALL], returns => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ] );

sub mutants ($settings) {
    return Test::Mutation::Runner::analyze( Test::Mutation::Settings::of_call($settings) )->{mutants};
}

signature_for mutation_score_ok => ( positional => [$CALL], returns => Bool );

sub mutation_score_ok ($settings) {
    my %settings = ( root => q{.}, $settings->%* );
    my $name     = delete $settings{name};
    $settings{min_score} = delete $settings{min} if exists $settings{min};

    # The command and the library run without the modules of a test file.
    require Test::Builder;
    require Test::Mutation::Report::Terminal;
    my $builder = Test::Builder->new;
    my $outer   = defined $ENV{TEST_MUTATION_ROOT} ? Cwd::abs_path( $ENV{TEST_MUTATION_ROOT} ) : undef;
    my $own     = Cwd::abs_path( $settings{root} );
    if ( defined $outer && defined $own && $outer eq $own ) {
        $builder->skip('inside a mutation run');
        return 1;
    }

    my $listener = delete $settings{on_event};
    my $config   = Test::Mutation::Settings::of_call( \%settings );
    my $minimum  = $config->min_score // 100;
    $name //= "the mutation score is at least $minimum%";
    my $result  = Test::Mutation::Runner::run( $config, $listener || sub { return } );
    my $outcome = Test::Mutation::Outcome::of( $result, $minimum );
    my $reached = $outcome->{exit}->code == Test::Mutation::Exit::of('success') ? 1 : 0;
    $builder->ok( $reached, $name );
    $builder->diag( Test::Mutation::Report::Terminal::render( $result, color => 0, floor => $minimum ) ) if !$reached;
    return $reached;
}

1;

__END__

=head1 NAME

Test::Mutation - mutation testing for Perl that never rewrites a source file

=head1 SYNOPSIS

    mutation run
    mutation list
    mutation show 4769d125ff17
    mutation exec 4769d125ff17 -- prove -l t/sign.t
    mutation merge part-1/mutation.json part-2/mutation.json

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
C<Timeout> means a test exceeded its time limit or printed past its output limit of 256 MiB, and no other test failed, which the score leaves out.
After a timeout the run tries the next test, and the second timeout ends the work on the mutant.
C<CompileError> means the mutant does not compile.
C<NoVerdict> means the run could not decide, for example because a test loaded the original file around the hook.
C<Ignored> means a comment suppressed the mutant, or the mutant compiles to code the run already knows.
Every state but C<Killed> and C<Survived> comes with a reason, such as C<time-limit> or C<loaded-around-hook>.

The score is the percentage of C<Killed> among C<Killed>, C<Survived>, and C<NoCoverage>.
The file C<mutation.json> writes each state with its name in the report schema, so a viewer of the file computes the same score.
A C<Timeout> is C<Ignored> there and a C<NoVerdict> is C<RuntimeError>, and the C<testMutation> key of each mutant keeps the state and its reason.

A mutant that no test detected compiles once more next to the original, and the run compares the two with L<B::Deparse>.
That covers a survivor and a mutant that no test reaches.
Equal code means no test can tell the two apart, so the mutant leaves the score.
A mutant in a field or in an C<ADJUST> block skips the comparison, because L<B::Deparse> prints neither.

C<mutation run --since origin/main> covers the changed lines, and C<--shard 2/4> covers one of four equal parts.
C<mutation merge> reads the C<mutation.json> of every part and reports the whole run, with its score and its exit status.
It refuses a set of files that misses a part or mixes two runs.
C<--cache> reuses the results of an earlier run for every mutant whose file and tests are unchanged.
C<mutation_score_ok> asserts a score from a test file.

=head1 CONFIGURATION

C<mutation run> measures modules in C<lib/> and Perl commands in C<bin/> and C<script/> with the tests under C<t/>.
The default test library is C<lib/>.
A file named C<mutation.toml> in the project directory changes the defaults, and C<--config> names another file.
A run writes its reports into C<mutation-report>, and C<--cache> keeps its results in C<.mutation>.
Both directories belong in C<.gitignore>.

A setting has one name: C<--min-score> on the command line, C<min-score> in the file, and C<min_score> in a call of the library.
The file holds one key for each setting and no sections, and every setting but C<root> and C<config> has its key.
A flag of the command line is C<true> or C<false> in the file, and C<--no-> before its name turns it off.
The command line beats the file, and the file beats the default, each with the whole value of a setting.

    jobs = 4
    cache = true
    cache-dir = ".mutation"
    keep-work = false

    source = ["lib/**/*.pm"]
    source-exclude = ["lib/Generated/**"]
    test = ["t/**/*.t"]
    test-exclude = ["t/fixtures/**"]

    perl = "/usr/bin/perl"
    switch = ["-Ilib"]
    timeout-factor = 4
    timeout-floor = 10
    baseline-timeout = 600
    coverage = "line"
    in-place = false
    link = ["local"]

    profile = "default"
    enable = ["regex-anchor"]
    disable = ["sub-body"]
    equivalence = true
    suppress-require-names = false
    suppress-require-reason = false

    report-dir = "mutation-report"
    format = ["terminal", "json", "html"]
    threshold-high = 80
    threshold-low = 60
    min-score = 70

The C<extended> profile adds mutators for literals, fixed conditions, sort order, range bounds, and patterns.
C<mutation list --profile extended> shows what a profile produces.
C<mutation mutators> prints the name, the profile, and the description of every mutator, for C<enable> and C<disable>.

A comment suppresses mutants in one of three forms, and the first line of a mutant decides whether a comment covers it.

    my $port = $base + 1;    ## no mutate
    ## no mutate (arithmetic, comparison-boundary): the limit is fixed
    my $limit = $port * 2 > 1024;
    ## use mutate
    ## no mutate sub: the banner is cosmetic
    sub banner ($name) { return "Hello, $name" }

C<## no mutate> behind code covers the mutants that start on its line.
C<## no mutate> on a line of its own opens a block that C<## use mutate> on a line of its own closes.
C<## no mutate sub> on a line of its own covers the named subroutine or method that follows, with its signature and its body.
Mutator names in parentheses after a space narrow each form to the mutants of those mutators, with a comma and a space between two names.
A reason may follow after a colon and a space, and the report shows it with every mutant that the comment suppresses.
C<--suppress-require-names> requires each suppression to name at least one mutator.
C<--suppress-require-reason> requires each suppression to give a reason.
Both requirements default to off.

A comment that resembles these forms, such as C<# no mutate> or C<##no mutate>, must have one of them exactly.
The run refuses such a comment in another form, an unknown mutator name, a C<## use mutate> without an open block, a second block inside an open one, a block that its file leaves open, and a C<## no mutate sub> before another statement.
It also refuses a comment that suppresses no mutant of any mutator, whatever mutators the run chooses.
The run collects the refusals of every file and ends as a usage error before it starts a test.

=head1 FUNCTIONS

=head2 run

    my $result = Test::Mutation::run( root => $directory, jobs => 4, on_event => sub ( $event, $data ) { } );

Measures the project and returns a L<Test::Mutation::Result>.
The settings are the attributes of L<Test::Mutation::Config>, and C<on_event> receives the progress events of L<Test::Mutation::Runner>.
C<root> is the working directory when the call leaves it out.
A C<mutation.toml> in the root directory, or the file that C<config> names, supplies the settings that the call leaves out.
The call refuses a name that is no setting, with the nearest one, and a value outside the type of its setting.

=head2 mutants

    my $mutants = Test::Mutation::mutants( root => $directory, profile => 'extended' );

Returns the L<Test::Mutation::Mutant> objects of the project without running a test.

=head2 mutation_score_ok

    mutation_score_ok( min => 80, name => 'tests detect mutants', jobs => 4, profile => 'extended' );

Measures the project in the current directory from a test file, which gets the function by loading the module.
Applies the same decision as the command.
The threshold is C<min>, the configured C<min-score>, or 100 in that order.
C<name> names the test, and every other setting goes to C<run>, which also reads C<mutation.toml>.
A failing assertion prints the report with the undetected mutants as diagnostics.
A test file under C<xt/> keeps the measurement out of the tests that a run itself starts.
Inside a run of the same project the assertion is a skip, so a copy under C<t/> does not start a run for every mutant.

=head1 LIMITS

The default run places the mutant in a private copy of the distribution.
Perl scripts and child interpreters, including taint-mode children, can load the mutant directly from the copy.
A test that loads the original path outside the copy can leave the verdict inconclusive.
With C<--in-place>, the run uses the module loading hook and reports files that bypass it.
A mutant runs with the rights of the tests.
An absolute path, a link that points out of the project, and a linked directory such as C<local> lead a test out of its copy.
With C<--in-place>, a mutant may create, change, or remove a file of the project.
The run then reports such a change and gives no verdict to a mutant that a test broken by the change detected.
C<mutation exec> runs its command in the project copy by default.
Linux and macOS are supported.

=head1 AUTHOR

Yasunobu Sakashita

=head1 LICENSE

Copyright (c) Yasunobu Sakashita.

MIT or Apache License 2.0, at your option.

=cut
