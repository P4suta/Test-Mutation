use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Capability;
use Fixture qw(ran write_file);

my $project = File::Temp::tempdir( CLEANUP => 1 );
Capability::need( 'git', length qx{git --version 2>/dev/null}, 'the pull request gate compares a revision' );
system( 'git', '-C', $project, 'init', '-q' ) == 0 or die 'git init failed';
system( 'git', '-C', $project, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Test', '-c',
    'user.email=test@example.invalid',
    'commit', '--allow-empty', '--no-gpg-sign', '-q', '-m', 'Start the test project' ) == 0
  or die 'git commit failed';
write_file( "$project/.gitignore", ".mutation/\nmutation-report/\nsummary.md\n" );
local $ENV{GITHUB_ACTIONS} = 'false';
my $source = "package Totals;\nsub sum { return \$_[0] + \$_[1] }\n1;\n";
write_file( "$project/lib/Totals.pm", $source );
write_file( "$project/t/sum.t",       "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 0), 4;\n" );
write_file( "$project/mutation.toml", "jobs = 1\n" );

sub elapsed ($report) {
    return $report =~ s/(\d+ jobs?, )\d+[.]\d s/$1TIME s/gr;
}

my $change       = 'a07c204622f4  lib/Totals.pm:2:24  arithmetic  replaced + with -';
my $columns      = 'File  Score  Killed  Survived  No coverage  Other';
my $reports      = 'Reports: mutation-report/mutation.json, mutation-report/mutation.html';
my $first_report = <<'REPORT';
Result: measured

3 mutants: 2 killed, 1 survived
Score: 66.7% (2 of 3 valid mutants)
1 test, 1 job, TIME s

File  Score  Killed  Survived  No coverage  Other
lib/Totals.pm  66.7%  2  1  0  -

lib/Totals.pm
  a07c204622f4  lib/Totals.pm:2:24  arithmetic  replaced + with -  [Survived]
    - sub sum { return $_[0] + $_[1] }
    + sub sum { return $_[0] - $_[1] }
    reached by t/sum.t

Next: mutation show a07c204622f4
Reports: mutation-report/mutation.json, mutation-report/mutation.html
REPORT
my $patch = <<'PATCH';
--- lib/Totals.pm
+++ lib/Totals.pm
@@ -1,3 +1,3 @@
 package Totals;
-sub sum { return $_[0] + $_[1] }
+sub sum { return $_[0] - $_[1] }
 1;
PATCH
my $listed = ran( 0, $project, 'list' )->{stdout};
my ($id) = $listed =~ /^([0-9a-f]{12})  .*  arithmetic  /m;
is $id, 'a07c204622f4', 'the catalog identifies the addition';
is ran( 0, $project, 'show', $id )->{stdout}, "$change\nLast result: unmeasured\n$patch",
  'a new project has no prior verdict';
my $first = ran( 0, $project );
is elapsed( $first->{stdout} ), $first_report, 'the complete first report names the next command';
ok -s "$project/mutation-report/mutation.json" && -s "$project/mutation-report/mutation.html",
  'both offline reports exist';
my $shown = ran( 0, $project, 'show', $id )->{stdout};
is $shown, "$change\nLast result: Survived\nReached by: t/sum.t\n$patch",
  'the survivor, the reaching test and the exact patch';
like ran( 0, $project, 'list', 'lib/Totals.pm' )->{stdout}, qr/^\Q$id\E  .*  \[Survived\]$/m,
  'the list identifies the measured survivor';

ran( 0, $project, '--mutant', 'b2a980f5c057', '--shard', '1/1', '--format', 'html' );
utime 1, 1, "$project/mutation-report/mutation.json" or die $!;
is ran( 0, $project, 'show', $id )->{stdout}, $shown,
  'an unrelated newer shard preserves the last measurement of the selected mutant';
like ran( 0, $project, 'list' )->{stdout}, qr/^\Q$id\E  .*  \[Survived\]$/m,
  'the list finds each verdict across saved formats';

local $ENV{GITHUB_STEP_SUMMARY} = "$project/summary.md";
my @gate = ( '--github', '--min-score', 100, '--since', 'HEAD', '--no-cache' );
my $gate = ran( 1, $project, @gate );
is elapsed( $gate->{stdout} ), $first_report =~ s/Result: measured\n/Result: measured\nGate: failed (minimum 100%)\n/r,
  'the complete changed-line report gives the failing gate';
like $gate->{stderr}, qr/^::warning file=lib\/Totals[.]pm,.*[(]\Q$id\E[)]$/m,
  'the pull request points to the same survivor';

write_file( "$project/t/positive.t", "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 1), 5;\n" );
my $narrow = ran( 0, $project, '--mutant', $id );
is elapsed( $narrow->{stdout} ),
  "Result: measured\n\n1 mutant: 1 killed\nScore: 100.0% (1 of 1 valid mutant)\n2 tests, 1 job, TIME s\n\n"
  . "$columns\nlib/Totals.pm  100.0%  1  0  0  -\n\nNext: mutation run --min-score 100\n$reports\n",
  'the focused measurement reports precisely the repaired survivor';
unlink "$project/mutation-report/mutation.json" or die $!;
is ran( 0, $project, 'show', $id )->{stdout},
  "$change\nLast result: Killed\nReached by: t/positive.t, t/sum.t\nKilled by: t/positive.t\n$patch",
  'the HTML report carries the killing test and the complete patch after a narrow rerun';
my $passed = ran( 0, $project, @gate );
is elapsed( $passed->{stdout} ),
  "Result: measured\nGate: passed (minimum 100%)\n\n3 mutants: 3 killed\nScore: 100.0% (3 of 3 valid mutants)\n2 tests, 1 job, TIME s\n\n"
  . "$columns\nlib/Totals.pm  100.0%  3  0  0  -\n\nNext: rerun mutation when the source or tests change\n$reports\n",
  'the full changed-line report passes after the test is strengthened';
unlike $passed->{stderr}, qr/^::warning/m, 'the passing job leaves no survivor annotation';
open my $summary, '<', $ENV{GITHUB_STEP_SUMMARY} or die $!;
my $decisions = do { local $/ = undef; readline $summary };
close $summary or die $!;
my $job = <<'SUMMARY';
## Mutation testing

Result: measured
Gate: failed (minimum 100%)

Score: **66.7%** (2 of 3 valid mutants)

| Killed | Survived | No coverage | Timeout | Compile error | No verdict | Ignored | Pending |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |

### Files

| File | Score | Killed | Survived | No coverage | Other |
| --- | --- | --- | --- | --- | --- |
| lib/Totals.pm | 66.7% | 2 | 1 | 0 | - |

### Mutants

| ID | Location | Mutator | Description | Status |
| --- | --- | --- | --- | --- |
| b2a980f5c057 | lib/Totals.pm:2:10 | sub-body | removed the body of sum | Killed |
| 6f7767472916 | lib/Totals.pm:2:18 | return-value | removed the return value | Killed |
| a07c204622f4 | lib/Totals.pm:2:24 | arithmetic | replaced + with - | Survived |

Next: mutation show a07c204622f4
SUMMARY
my $green =
  $job =~ s/Gate: failed/Gate: passed/r =~ s/66[.]7%/100.0%/gr =~ s/2 of 3/3 of 3/r =~
  s/[|] 2 [|] 1 [|]/| 3 | 0 |/gr =~ s/with - [|] Survived/with - | Killed/r =~
  s/Next: mutation show a07c204622f4/Next: rerun mutation when the source or tests change/r;
is $decisions, $job . $green, 'both job summaries retain every file and mutant in the failing and passing gates';
write_file( "$project/lib/Totals.pm", $source . "# Changed after the last measurement.\n" );
like ran( 0, $project, 'show', $id )->{stdout}, qr/^Last result: unmeasured$/m,
  'a different source cannot borrow the saved verdict';

done_testing;
