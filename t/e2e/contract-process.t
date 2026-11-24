use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Cwd        ();
use File::Temp ();
use Fixture    qw(copy_of ran tree_digest write_file);
use Gate;
use Invariants;
use Space;
use Test::Mutation::Exit;

# A sample of the contract in real processes: what the tables call for, and what the command does.
# The cases in t/contract plan in one process, and these cases show the same contract at the command line.

my @codes   = map { $_->code } Test::Mutation::Exit::rows()->@*;
my $outside = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $marker  = "$outside/started";

# The sentinel writes to a place outside the project and the temporary directory, so a copy of the project writes there too.
my $sentinel = "use Test::More tests => 1;\nopen my \$mark, '>>', '$marker' or die \"mark: \$!\";\n"
  . "print {\$mark} \"started\\n\" or die \"mark: \$!\";\nclose \$mark or die \"mark: \$!\";\nok 1, 'the sentinel';\n";
my $root = copy_of('calc');
write_file( "$root/t/sentinel.t", $sentinel );
my $tiny   = Space::tree( 't/sentinel.t'  => $sentinel );
my $empty  = Space::tree( 'lib/Tiny.pm'   => undef, 'lib/Other.pm' => undef, 't/sentinel.t' => $sentinel );
my $typed  = Space::tree( 'mutation.toml' => "jobs = 0\n" );
my $keyed  = Space::tree( 'mutation.toml' => "[mutators]\nprofil = \"default\"\n" );
my $truthy = Space::tree( 'mutation.toml' => "cache = true\n" );
my $broken = Space::tree( 't/broken.t'    => "use Test::More tests => 1;\nis 1, 2, 'never equal';\n" );
my $wide   = Space::tree(
    'lib/Tiny.pm'  => "package Tiny;\nuse strict;\nuse warnings;\nsub greet { return '\xE6\x97\xA5 ' . \$_[0] }\n1;\n",
    'lib/Other.pm' => undef
);

# The decoder of the configuration file takes its booleans from this module where a machine has it.
my $serialiser = <<'PERL';
package Types::Serialiser;
use strict;
use warnings;
our $VERSION = '1.01';
my ( $yes, $no ) = ( 1, 0 );
sub true  { return bless \$yes, 'Types::Serialiser::Boolean' }
sub false { return bless \$no,  'Types::Serialiser::Boolean' }

package Types::Serialiser::Boolean;
use overload 'bool' => sub { ${ $_[0] } }, '0+' => sub { ${ $_[0] } }, q{""} => sub { ${ $_[0] } }, fallback => 1;
1;
PERL
write_file( "$outside/modules/Types/Serialiser.pm", $serialiser );

sub first_identifier ($project) {
    my ($identifier) = ran( 0, $project, 'list' )->{stdout} =~ /\A([0-9a-f]{12})  /;
    return $identifier;
}
my $calc    = first_identifier($root);
my $letters = first_identifier($wide);

# Each case: its name, the part of the contract it belongs to, the project, the exit status that the tables call for,
# and the command line.
my @run   = ( '--format', 'terminal', '--jobs', 2 );
my @cases = (
    [ 'version',              'commands',  $root,   0, '--version' ],
    [ 'help',                 'commands',  $root,   0, '--help' ],
    [ 'help-after-run',       'commands',  $root,   0, 'run',      '--help' ],
    [ 'help-after-list',      'commands',  $root,   0, 'list',     '-h' ],
    [ 'help-after-mutators',  'commands',  $root,   0, 'mutators', '--help' ],
    [ 'version-after-list',   'commands',  $root,   0, 'list',     '--version' ],
    [ 'word-help',            'commands',  $root,   2, 'help' ],
    [ 'word-lst',             'commands',  $root,   2, 'lst' ],
    [ 'operand-of-list',      'commands',  $root,   2, 'list',     'lib/Calc.pm' ],
    [ 'operand-of-show',      'commands',  $root,   2, 'show',     $calc, 'surplus' ],
    [ 'operand-of-run',       'commands',  $root,   2, 'run',      'surplus' ],
    [ 'operand-of-mutators',  'commands',  $root,   2, 'mutators', 'surplus' ],
    [ 'show-without-id',      'commands',  $root,   2, 'show' ],
    [ 'exec-without-command', 'commands',  $root,   2, 'exec', $calc ],
    [ 'merge-without-file',   'commands',  $root,   2, 'merge' ],
    [ 'abbreviation',         'settings',  $root,   2, 'list', '--jo',   2 ],
    [ 'unknown-option',       'settings',  $root,   2, 'list', '--jobz', 2 ],
    [ 'missing-value',        'settings',  $root,   2, 'list', '--jobs' ],
    [ 'word-for-a-number',    'settings',  $root,   2, 'list', '--jobs',      'x' ],
    [ 'number-out-of-range',  'settings',  $root,   2, 'list', '--jobs',      0 ],
    [ 'gate-out-of-range',    'settings',  $root,   2, 'list', '--min-score', 120 ],
    [ 'negated-value',        'settings',  $root,   2, 'list', '--no-jobs' ],
    [ 'value-for-a-flag',     'settings',  $root,   2, 'list', '--cache=1' ],
    [ 'options-after-dashes', 'settings',  $root,   2, 'list', q{--}, '--jobs', 2 ],
    [ 'missing-config',       'settings',  $root,   2, 'list', '--config', 'absent.toml' ],
    [ 'value-in-the-file',    'settings',  $typed,  2, 'list' ],
    [ 'key-in-the-file',      'settings',  $keyed,  2, 'list' ],
    [ 'boolean-in-the-file',  'settings',  $truthy, 0, 'list' ],
    [ 'missing-directory',    'selection', $root,   2, '--root', 'absent', 'list' ],
    [ 'missing-report',       'selection', $root,   2, 'merge',  'absent.json' ],
    [ 'unmatched-source',     'selection', $root,   2, 'list',   '--source', 'nothing/**' ],
    [ 'unmatched-mutant',     'selection', $root,   2, 'list',   '--mutant', 'zzzz' ],
    [ 'unknown-identifier',   'selection', $root,   2, 'show',   'zzzz' ],
    [ 'unknown-mutator',      'selection', $tiny,   2, 'run',    @run,      '--enable', 'nonesuch' ],
    [ 'unmatched-test',       'selection', $tiny,   2, 'run',    @run,      '--test',   't/nothing*.t' ],
    [ 'missing-interpreter',  'selection', $tiny,   2, 'run',    @run,      '--perl',   '/nonesuch/bin/perl' ],
    [ 'unknown-revision',     'selection', $tiny,   2, 'list',   '--since', 'no..such..revision' ],
    [ 'letters-in-a-patch',   'report',    $wide,   0, 'show',   $letters ],
    [ 'no-source-and-a-gate', 'outcome',   $empty,  4, 'run',    @run, '--min-score', 50 ],
    [ 'measured',             'outcome',   $tiny,   0, 'run',    @run ],
    [ 'below-the-gate',       'outcome',   $tiny,   1, 'run',    @run, '--min-score', 100 ],
    [ 'failing-baseline',     'outcome',   $broken, 3, 'run',    @run ],
);

my %violations;
my $started  = 0;
my $progress = q{};
for my $case (@cases) {
    my ( $name, $part, $project, $expected, @line ) = $case->@*;
    my $before = tree_digest($project);
    my $run;
    my $outcomes = do {

        # A job of GitHub Actions sets the first two, and a command that read them would answer another way there.
        local @ENV{qw(GITHUB_ACTIONS GITHUB_STEP_SUMMARY NO_COLOR)} = ();
        delete @ENV{qw(GITHUB_ACTIONS GITHUB_STEP_SUMMARY NO_COLOR)};
        local $ENV{PERL5LIB} = join q{:}, "$outside/modules", defined $ENV{PERL5LIB} ? $ENV{PERL5LIB} : ();
        Gate::outcomes( sub { $run = ran( $expected, $project, @line ) } );
    };
    my $observation = { $run->%*, warnings => [] };
    my $ran         = -e $marker ? 1 : 0;
    $started += $ran;
    $progress = $run->{stderr} if $name eq 'measured';
    if ($ran) {
        unlink $marker or die "unlink $marker: $!";
    }
    my @changed  = $expected == 2 ? Space::differences( $before, tree_digest($project) )->@* : ();
    my %symptoms = (
        'exit-domain' => [ Invariants::exit_domain( $observation, \@codes ) ],
        'exit-table'  => [ Invariants::exit_table( $observation, $expected ) ],
        'one-line'    => [ Invariants::one_line($observation) ],
        'no-leak'     => [ Invariants::no_leak($observation) ],
        'no-effect'   => [
            ( $outcomes->[1] eq 'pass' ? () : 'the command left a file in the temporary directory or the project' ),
            ( $expected == 2 && $ran   ? 'a test started before the refusal'      : () ),
            ( @changed                 ? 'the project changed before the refusal' : () ),
        ],
        stdout => [ Invariants::stdout($observation) ],
    );
    for my $gate ( sort keys %symptoms ) {
        push $violations{$gate}->@*, map { [ $_, $name, $part ] } $symptoms{$gate}->@*;
    }
}

ok $started, 'the sentinel reports the tests of a run that measures';

# The progress space of t/contract sends these events in this order from a made run, after the count of processors.
my $PROCESSORS = qr/\d+ processors? (?:online|in the [a-z ]+|by default)\n/;
like $progress,
  qr/\A$PROCESSORS\d+ mutants? in \d+ files?, \d+ tests?\nThe unmodified run passed: [^\n]+\n(?:\[\s*\d+\/\d+\][^\n]*\n)+\z/,
  'a run reports its processors, its analysis, then the end of the unmodified run, then each mutant';
Gate::checked( 'command lines in a process', scalar @cases, at_least => 40 );

for my $gate (qw(exit-domain exit-table one-line no-leak no-effect stdout)) {
    Gate::findings( "contract-$gate-process", Space::folded( $violations{$gate} || [], 'cases', 'part' ) );
}

done_testing;
