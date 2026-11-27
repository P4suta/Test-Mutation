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
Scope: configured sources
Undetected: 1
Result: measured

3 mutants: 2 killed, 1 survived
Score: 66.7% (2 of 3 valid mutants)
1 test, 1 job, TIME s

lib/Totals.pm
  a07c204622f4  lib/Totals.pm:2:24  arithmetic  replaced + with -  [Survived]
    - sub sum { return $_[0] + $_[1] }
    + sub sum { return $_[0] - $_[1] }
    reached by t/sum.t
    Recheck: mutation run --mutant a07c204622f4

File  Score  Killed  Survived  No coverage  Other
lib/Totals.pm  66.7%  2  1  0  -

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
my ($stamp) = $shown =~ /^Measured at: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$/m;
ok defined $stamp, 'show records the measurement time in UTC';
is $shown, "$change\nLast result: Survived\nMeasured at: $stamp\nReached by: t/sum.t\n$patch",
  'the survivor, the reaching test and the exact patch';
like ran( 0, $project, 'list', 'lib/Totals.pm' )->{stdout}, qr/^\Q$id\E  .*  \[Survived\] \Q$stamp\E$/m,
  'the list identifies the measured survivor';

ran( 0, $project, '--mutant', 'b2a980f5c057', '--shard', '1/1', '--format', 'html' );
utime 1, 1, "$project/mutation-report/mutation.json" or die $!;
is ran( 0, $project, 'show', $id )->{stdout}, $shown,
  'an unrelated newer shard preserves the last measurement of the selected mutant';
like ran( 0, $project, 'list' )->{stdout}, qr/^\Q$id\E  .*  \[Survived\] \Q$stamp\E$/m,
  'the list finds each verdict across saved formats';

local $ENV{GITHUB_STEP_SUMMARY} = "$project/summary.md";
my @gate = ( '--github', '--min-score', 100, '--since', 'HEAD', '--no-cache' );
my $gate = ran( 1, $project, @gate );
is elapsed( $gate->{stdout} ),
  $first_report =~ s/Scope: configured sources/Scope: changes since HEAD/r =~
  s/Result: measured\n/Result: measured\nGate: failed (minimum 100%)\n/r,
  'the complete changed-line report gives the failing gate';
like $gate->{stderr}, qr/^::warning file=lib\/Totals[.]pm,.*[(]\Q$id\E[)]$/m,
  'the pull request points to the same survivor';

write_file( "$project/t/positive.t", "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 1), 5;\n" );
my $narrow = ran( 0, $project, '--mutant', $id );
is elapsed( $narrow->{stdout} ),
  "Scope: mutant $id\nUndetected: 0\nResult: measured\n\n1 mutant: 1 killed\nScore: 100.0% (1 of 1 valid mutant)\n2 tests, 1 job, TIME s\n\n"
  . "$columns\nlib/Totals.pm  100.0%  1  0  0  -\n\nNext: mutation run --min-score 100\n$reports\n",
  'the focused measurement reports precisely the repaired survivor';
unlink "$project/mutation-report/mutation.json" or die $!;
my $killed = ran( 0, $project, 'show', $id )->{stdout};
my ($killed_at) = $killed =~ /^Measured at: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$/m;
ok defined $killed_at, 'the focused measurement records its own time';
is $killed,
  "$change\nLast result: Killed\nMeasured at: $killed_at\nReached by: t/positive.t, t/sum.t\nKilled by: t/positive.t\n$patch",
  'the HTML report carries the killing test and the complete patch after a narrow rerun';
my $passed = ran( 0, $project, @gate );
is elapsed( $passed->{stdout} ),
  "Scope: changes since HEAD\nUndetected: 0\nResult: measured\nGate: passed (minimum 100%)\n\n3 mutants: 3 killed\nScore: 100.0% (3 of 3 valid mutants)\n2 tests, 1 job, TIME s\n\n"
  . "$columns\nlib/Totals.pm  100.0%  3  0  0  -\n\nNext: rerun mutation when the source or tests change\n$reports\n",
  'the full changed-line report passes after the test is strengthened';
unlike $passed->{stderr}, qr/^::warning/m, 'the passing job leaves no survivor annotation';
open my $summary, '<', $ENV{GITHUB_STEP_SUMMARY} or die $!;
my $decisions = do { local $/ = undef; readline $summary };
close $summary or die $!;
my $job = <<'SUMMARY';
## Mutation testing

Scope: changes since HEAD
Undetected: 1
Result: measured
Gate: failed (minimum 100%)

Score: **66.7%** (2 of 3 valid mutants)

| Killed | Survived | No coverage | Timeout | Compile error | No verdict | Ignored | Pending |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |

### Undetected changes

| ID | Location | Change | Status |
| --- | --- | --- | --- |
| a07c204622f4 | lib/Totals.pm:2:24 | replaced + with - | Survived |

Detailed reports: mutation-report/mutation.json, mutation-report/mutation.html

Next: mutation show a07c204622f4
SUMMARY
my $green =
  $job =~ s/Undetected: 1/Undetected: 0/r =~ s/Gate: failed/Gate: passed/r =~ s/66[.]7%/100.0%/r =~
  s/2 of 3/3 of 3/r =~ s/[|] 2 [|] 1 [|]/| 3 | 0 |/r =~
  s/\n### Undetected changes\n.*?\n\nDetailed reports:/\nDetailed reports:/sr =~
  s/Next: mutation show a07c204622f4/Next: rerun mutation when the source or tests change/r;
is $decisions, $job . $green, 'both job summaries name the score, remaining gaps and complete reports';
write_file( "$project/lib/Totals.pm", $source . "# Changed after the last measurement.\n" );
like ran( 0, $project, 'show', $id )->{stdout}, qr/^Last result: unmeasured$/m,
  'a different source cannot borrow the saved verdict';

done_testing;
