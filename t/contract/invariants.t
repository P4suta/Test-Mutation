use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Invariants;
use Space;
use Test::Mutation::Settings;

# Every invariant rejects one observation and accepts another, so a check that judges nothing fails here.

sub observation (%fact) {
    return { exit => 0, stdout => q{}, stderr => q{}, warnings => [], %fact };
}

my $refusal = observation( exit => 2, stderr => "mutation: --jobs takes a whole number above zero, and 0 is none\n" );
my %setting = map { $_->name => $_ } Test::Mutation::Settings::rows()->@*;

subtest 'exit-domain rejects a status outside the table' => sub {
    is [ Invariants::exit_domain( observation( exit => 2 ), [ 0, 1, 2 ] ) ], [], 'a status of the table';
    is [ Invariants::exit_domain( observation( exit => 255 ), [ 0, 1, 2 ] ) ], ['status 255 stands in no table'],
      'the status of a crash';
};

subtest 'exit-table rejects another status than the outcome calls for' => sub {
    is [ Invariants::exit_table( $refusal, 2 ) ], [], 'a usage error with status 2';
    is [ Invariants::exit_table( observation( exit => 4 ), 2 ) ], ['status 4, where the table calls for 2'],
      'a usage error with status 4';
};

subtest 'one-line rejects an error without its one line' => sub {
    is [ Invariants::one_line($refusal) ],        [], 'one line with the prefix';
    is [ Invariants::one_line( observation() ) ], [], 'success needs no line';
    is [
        Invariants::one_line(
            observation( exit => 130, stderr => "[1/2] 1 killed\nmutation: interrupted by SIGINT\n" )
        )
      ],
      [],
      'progress before the line of a run';
    is [ Invariants::one_line( observation( exit => 2, stderr => "Unknown option: x\n" ) ) ],
      ['no line with the prefix'],
      'a line without the prefix';
    is [ Invariants::one_line( observation( exit => 1 ) ) ], ['no line with the prefix'], 'a failure without a word';
    is [ Invariants::one_line( observation( exit => 2, stderr => "mutation: a\nmutation: b\n" ) ) ],
      ['several lines with the prefix'], 'two lines';
    is [ Invariants::one_line( observation( exit => 4, stderr => "mutation: a\nmore\n" ) ) ],
      ['text after the line with the prefix'], 'text after the line';
    is [ Invariants::one_line( observation( exit => 2, stderr => "note\nmutation: a\n" ) ) ],
      ['other lines before the refusal'],
      'text before a refusal';
};

subtest 'no-leak rejects the traces of the code' => sub {
    is [ Invariants::no_leak($refusal) ], [], 'a message in the words of the user';
    my %leak = (
        'a place in the source'        => 'mutation: it broke at lib/Test/Mutation/CLI.pm line 12.',
        'a package name'               => 'mutation: Test::Mutation::Config refused it',
        'a variable of the code'       => 'mutation: bad value (in $args->{"jobs"})',
        'wording of the type library'  => 'mutation: Value "x" did not pass',
        'wording of the option parser' => 'Unknown option: jobz',
    );
    is [ Invariants::no_leak( observation( exit => 2, stderr => "$leak{$_}\n" ) ) ], [$_], $_ for sort keys %leak;
    is [ Invariants::no_leak( observation( warnings => ["Wide character in print at x line 1.\n"] ) ) ],
      ['a warning of Perl'],
      'a warning of Perl';
};

subtest 'typed-name rejects a message without the spelling of the user' => sub {
    is [ Invariants::typed_name( $refusal, '--jobs', 'jobs' ) ], [], 'the flag as the user typed it';
    is [ Invariants::typed_name( observation( stderr => "Unknown option: jobz\n" ), '--jobz' ) ],
      ['the message lacks the spelling that the user typed'], 'the flag without its dashes';
    is [
        Invariants::typed_name(
            observation( stderr => "mutation: --min-score: threshold_break is bad\n" ), '--min-score',
            'threshold_break'
        )
      ],
      ['the message names the attribute'], 'the name of another surface';
};

subtest 'unknown rejects a refusal without the nearest name' => sub {
    is [ Invariants::nearest( observation( stderr => "mutation: no command lst; the nearest is list\n" ), 'list' ) ],
      [],
      'the nearest name';
    is [ Invariants::nearest( observation( stderr => "mutation: unexpected argument lst\n" ), 'list' ) ],
      ['the refusal names no nearest name'], 'no other name';
};

subtest 'help rejects a word that prints no help' => sub {
    is [ Invariants::help( observation( stdout => "Usage\n" ), "Usage\n" ) ], [], 'the text, success, and no error';
    is [ Invariants::help( observation( exit => 2 ),     "Usage\n" ) ], ['status 2'],            'a refusal';
    is [ Invariants::help( observation( exit => undef ), "Usage\n" ) ], ['the command goes on'], 'a command that runs';
    is [ Invariants::help( observation( stdout => "other\n" ), "Usage\n" ) ], ['another text'],  'another text';
    is [ Invariants::help( observation( stdout => "Usage\n", stderr => "note\n" ), "Usage\n" ) ],
      ['text on standard error'],
      'a note on standard error';
};

subtest 'one-name rejects a setting with two names' => sub {
    is [ Invariants::one_name( $setting{perl} ) ], [], 'one name on every surface that has it';
    is [ Invariants::one_name( $setting{threshold_break} ) ], ['--min-score, [thresholds] break, threshold_break'],
      'three names for one setting';
};

subtest 'all-surfaces rejects a setting that a surface lacks' => sub {
    is [ Invariants::all_surfaces( $setting{jobs} ) ],             [], 'a setting on all three';
    is [ Invariants::all_surfaces( $setting{baseline_timeout} ) ], [ 'flag', 'file' ], 'a setting of the library alone';
    is [ Invariants::all_surfaces( $setting{config} ) ], [ 'file', 'library' ], 'a setting of the command line alone';
};

subtest 'same-config rejects a surface that answers another way' => sub {
    is [ Invariants::same_config( 'valid',   '2', '2' ) ],   [], 'the value of the sample';
    is [ Invariants::same_config( 'invalid', 'x', undef ) ], [], 'a refusal of an invalid sample';
    is [ Invariants::same_config( 'valid',   '2', undef ) ], ['a valid sample: refused'], 'a refusal of a valid sample';
    is [ Invariants::same_config( 'valid',   '2', '3' ) ],   ['a valid sample: another value'], 'another value';
    is [ Invariants::same_config( 'invalid', 'x', 'x' ) ], ['an invalid sample: accepted'],
      'an invalid sample that passes';
};

subtest 'selector rejects a selector that selects nothing without a refusal' => sub {
    my $named = observation( exit => 2, stderr => "mutation: --source lib/Nothing*.pm matches no file\n" );
    is [ Invariants::selector( $named,        2, 'lib/Nothing*.pm' ) ], [], 'a usage error that names the selector';
    is [ Invariants::selector( observation(), 0, 'lib/Tiny.pm' ) ],     [], 'a selector that matches';
    is [ Invariants::selector( observation(), 2, 'lib/Nothing*.pm' ) ], ['status 0, where the selector calls for 2'],
      'success';
    is [ Invariants::selector( observation( exit => 2, stderr => "mutation: no file\n" ), 2, 'lib/Nothing*.pm' ) ],
      ['the refusal lacks the selector'], 'a refusal without the selector';
};

subtest 'no-effect rejects a refusal after a copy or a test' => sub {
    is [ Invariants::no_effect( {} ) ], [], 'nothing started';
    is [ Invariants::no_effect( { copies => 1, tests => 2 } ) ],
      [ 'the project was copied before the refusal', 'a test started before the refusal' ], 'a copy and a test';
};

subtest 'stdout rejects text on the wrong stream' => sub {
    is [ Invariants::stdout($refusal) ], [], 'a refusal on standard error alone';
    is [ Invariants::stdout( observation( stdout => "2 mutants: 2 killed\n", stderr => "[2/2] 2 killed\n" ) ) ], [],
      'the report on standard output and the progress on standard error';
    is [ Invariants::stdout( observation( exit => 2, stdout => "0 mutants\n" ) ) ],
      ['a refusal prints to standard output'],
      'a refusal with output';
    is [ Invariants::stdout( observation( stdout => "[1/2] 1 killed\n" ) ) ], ['a progress line on standard output'],
      'progress on standard output';
    is [ Invariants::stdout( observation( stderr => "Score: 50.0% (1 of 2 valid mutants)\n" ) ) ],
      ['the report of the run on standard error'], 'the report on standard error';
};

subtest 'stdout rejects bytes that are another text than the report' => sub {
    my $report = "- caf\x{e9} \x{65e5}\n";
    is [ Invariants::encoded( "- caf\xC3\xA9 \xE6\x97\xA5\n", $report ) ], [], 'the report in UTF-8';
    is [ Invariants::encoded( "- caf\xE9\n", "- caf\x{e9}\n" ) ],
      ['the bytes of the output are no UTF-8 form of the report'],
      'a letter as one byte of Latin-1';
    is [ Invariants::encoded( "- cafe\n", "- caf\x{e9}\n" ) ],
      ['the bytes of the output are no UTF-8 form of the report'],
      'another letter';
};

subtest 'the outcome of a result calls for one exit status' => sub {
    my $exit = sub ( $counts, %fact ) { [ Invariants::outcome( $counts, %fact ) ] };
    is $exit->( { Killed => 1, Pending => 1 }, signal => 130 ), [ 'interrupted', 130 ],   'a signal';
    is $exit->( {}, baseline_failed => 1, gate => 50 ),         [ 'baseline-failed', 3 ], 'a failing unmodified run';
    is $exit->( { Killed => 1, RuntimeError => 1 } ),           [ 'inconclusive', 4 ],    'a mutant without a verdict';
    is $exit->( { Timeout => 1 } ),                             [ 'inconclusive', 4 ], 'timeouts and no valid mutant';
    is $exit->( { Killed => 1, Survived => 1 } ),               [ 'measured', 0 ],     'no gate';
    is $exit->( { Killed => 1, Survived => 1 }, gate => 50 ),   [ 'measured', 0 ],     'a score at the gate';
    is $exit->( { Killed => 1, Survived => 1 }, gate => 51 ),   [ 'measured', 1 ],     'a score below the gate';
    is $exit->( { Survived => 1 }, gate => 51, part => 1 ), [ 'measured', 0 ], 'a part leaves the gate to the merge';
    is $exit->( { Ignored => 1 } ),                         [ 'nothing', 0 ],  'no valid mutant and no gate';
    is $exit->( {}, gate => 0 ),                            [ 'nothing', 4 ],  'no valid mutant under a gate';
    is $exit->( {}, gate => 0, part => 1 ),                 [ 'nothing', 0 ],  'an empty part';
};

subtest 'gate rejects success that no score earned' => sub {
    is [ Invariants::gate( { Killed => 1, Survived => 1 }, 0, { 0 => 0, 50 => 0, 100 => 1 } ) ], [],
      'a score that meets the gates it passes';
    is [ Invariants::gate( {}, 1, { 0 => 0, 50 => 0 } ) ], [],                          'an empty part';
    is [ Invariants::gate( {}, 0, { 0 => 0, 50 => 0 } ) ], ['success without a score'], 'an empty run';
    is [ Invariants::gate( { Survived => 1 }, 0, { 0 => 0, 50 => 0 } ) ], ['success with a score below it'],
      'a low score';
    is [ Invariants::gate( { Killed => 1 }, 0, { 0 => 1, 50 => 0 } ) ], ['a higher gate turns a failure into success'],
      'a gate that helps';
};

subtest 'three-deciders rejects deciders that disagree' => sub {
    is [ Invariants::three_deciders( run => 1, merge => 1,     assertion => 1 ) ], [], 'all pass';
    is [ Invariants::three_deciders( run => 0, merge => undef, assertion => 0 ) ], [], 'all fail, and one is left out';
    is [ Invariants::three_deciders( run => 1, merge => 1, assertion => 0 ) ], ['pass: merge, run; fail: assertion'],
      'one decider fails alone';
};

subtest 'independent rejects a pair that differs from its two settings' => sub {
    my %base = ( jobs => 3, cache => 0, formats => 'terminal json html' );
    my %one  = ( %base, jobs  => 2 );
    my %two  = ( %base, cache => 1 );
    is [ Invariants::independent( \%base, \%one, \%two, { %base, jobs => 2, cache => 1 } ) ], [],
      'each setting keeps its value in the pair';
    is [ Invariants::independent( \%base, \%one, \%two, { %base, jobs => 2 } ) ], ['cache'],
      'a value that the pair loses';
    is [ Invariants::independent( \%base, \%one, \%two, { %base, jobs => 2, cache => 1, formats => 'json' } ) ],
      ['formats'],
      'a value that neither setting gives';
    is [ Invariants::independent( \%base, \%one, \%two, undef ) ], ['the pair is refused'], 'a pair that is refused';
};

subtest 'round-trip rejects a report that loses a status or a reason' => sub {
    my @written = (
        { id => 'a', status => 'Killed',  reason => 't/a.t failed' },
        { id => 'b', status => 'Timeout', reason => undef }
    );
    my @other =
      ( { id => 'b', status => 'Ignored', reason => undef }, { id => 'a', status => 'Killed', reason => undef } );
    is [ Invariants::round_trip( \@written, [ reverse @written ] ) ],       [], 'the same statuses and reasons';
    is [ Invariants::round_trip( \@written, [ $written[0], $other[0] ] ) ], ['a status changes'], 'another status';
    is [ Invariants::round_trip( \@written, [ $other[1], $written[1] ] ) ], ['a reason changes'], 'a lost reason';
    is [ Invariants::round_trip( \@written, [ $written[0] ] ) ],            ['a mutant is gone'], 'a lost mutant';
};

subtest 'role rejects a score that the formula of the report schema gives another way' => sub {
    my @differs = ('the score differs from the formula of the report schema');
    is [ Invariants::role( { Killed  => 1, Survived => 1 }, 50 ) ],    [], 'detected among valid';
    is [ Invariants::role( { Ignored => 2 },                undef ) ], [], 'no valid mutant and no score';
    is [ Invariants::role( { Killed  => 1, Survived => 1, Timeout => 2 }, 50 ) ], \@differs,
      'a timeout counts as detected there';
    is [ Invariants::role( { Timeout => 1 }, undef ) ], \@differs, 'a timeout alone has a score there';
};

subtest 'counts rejects a report that states another count' => sub {
    is [ Invariants::counts( { Killed => 2, Timeout => 1 }, { Killed => 2, Timeout => 1, Survived => 0 } ) ], [],
      'the counts of the result';
    is [ Invariants::counts( { Killed => 2, Timeout => 1 }, { Killed => 2 } ) ],
      [ [ 'the report states no count', 'Timeout' ] ],
      'a status without a count';
    is [ Invariants::counts( { Killed => 2 }, { Killed => 1 } ) ], [ [ 'the report states another count', 'Killed' ] ],
      'another count';
};

subtest 'progress-sum rejects a line whose counts miss its position' => sub {
    is [ Invariants::progress_sum( [ '[1/2] 1 killed', '[2/2] 1 killed, 1 no coverage' ] ) ], [],
      'counts that sum to the position';
    is [ Invariants::progress_sum( [ '[1/2]', '[2/2] 1 killed' ] ) ],
      ['the counts of a line sum to less than its position'],
      'a mutant that no count holds';
    is [ Invariants::progress_sum( ['[1/2] 2 killed'] ) ], ['the counts of a line sum to more than its position'],
      'a mutant that two counts hold';
};

subtest 'progress-final rejects a last line that differs from the tally' => sub {
    my %word = ( Killed => 'killed', Ignored => 'ignored', NoCoverage => 'no coverage' );
    is [
        Invariants::progress_final(
            [ '[1/2] 1 killed', '[2/2] 1 killed, 1 no coverage' ],
            { Killed => 1, NoCoverage => 1 }, \%word
        )
      ],
      [],
      'the tally of the result';
    is [ Invariants::progress_final( [], {}, \%word ) ], [], 'a run without a mutant has no line';
    is [ Invariants::progress_final( ['[2/2] 1 killed'], { Killed => 1, Ignored => 1 }, \%word ) ], ['Ignored'],
      'a status that the last line lacks';
    is [ Invariants::progress_final( ['[1/2] 1 killed'], { Killed => 2 }, \%word ) ], ['Killed'],
      'a line before the end';
    is [ Invariants::progress_final( [], { Killed => 1 }, \%word ) ], ['Killed'], 'no line at all';
};

subtest 'liveness rejects a silence that grows with the run' => sub {
    is [ Invariants::liveness( 1, 1 ) ],   [], 'the same silence in a small and a large run';
    is [ Invariants::liveness( 1, 100 ) ], ['the silence grows with the run'], 'a longer silence in the large run';
};

subtest 'message rejects a message that no case produces' => sub {
    my $value    = "\x{2026}";
    my @messages = ( "cannot read $value: $value", "cannot write $value: $value", 'merge needs at least one report' );
    my @texts    = ( "mutation: cannot read a.toml: No such file or directory\n", 'merge needs at least one report' );
    is [ Invariants::message( \@messages, \@texts ) ], ["cannot write $value: $value"],
      'a text may stand behind the name of the command, and a message without a text is left';
    is [
        Invariants::message(
            [ 'a location lies outside the source of ' . $value ],
            ['the report is malformed: a location lies outside the source of lib/A.pm']
        )
      ],
      [], 'a message inside another message';
    is [ Invariants::message( ['cannot read the file'], ['cannot read the file of settings'] ) ],
      ['cannot read the file'],
      'a longer text is another message';
};

subtest 'the fold rejects a line that hides where a violation holds' => sub {
    my @violations = (
        [ 'typo: refused badly', '--jobs', 'run' ],
        [ 'typo: refused badly', '--jobs', 'list' ],
        [ 'typo: refused badly', '--perl', 'run' ],
        [ 'typo: refused badly', '--perl', 'list' ],
        [ 'typo: refused badly', '--root', 'run' ]
    );
    is Space::folded( \@violations ),
      [
        'typo: refused badly; flags --jobs --perl; commands list run',
        'typo: refused badly; flags --root; commands run'
      ],
      'the flags that share their commands share a line, and another set of commands has a line of its own';
    is Space::folded( [ reverse @violations ] ), Space::folded( \@violations ),
      'the order of the violations leaves the lines as they are';
    is Space::folded( [], 'settings', 'surfaces' ), [], 'no violation gives no line';
};

done_testing;
