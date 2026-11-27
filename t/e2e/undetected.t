use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(ran write_file);
use Test::Mutation::Report::Json;
use Test::Mutation::Source;
use Test::Mutation ();

my $project = File::Temp::tempdir( CLEANUP => 1 );
write_file( "$project/lib/Totals.pm", "package Totals;\nsub sum { return \$_[0] + \$_[1] }\n1;\n" );
write_file( "$project/t/sum.t",       "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 0), 4;\n" );
my @options = ( '--format', 'terminal', '--jobs', 1 );

my $initial = ran( 2, $project, 'run', '--undetected', @options );
like $initial->{stderr}, qr/no completed measurement.*mutation run/,
  'the first use explains how to collect a measurement';
unlike $initial->{stderr},                           qr/Baseline \(/,  'requesting missing history launches no tests';
like ran( 0, $project, 'help', 'run' )->{stdout},    qr/--undetected/, 'run help describes the selection';
unlike ran( 0, $project, 'help', 'list' )->{stdout}, qr/--undetected/, 'the recheck belongs to run';

my $ordinary = ran( 0, $project, 'run', @options );
my ($id) = $ordinary->{stdout} =~ /^  ([a-f0-9]+)  .*?\[Survived\]/m;
ok defined $id, 'the original test misses the arithmetic change';
my $api = Test::Mutation::run( root => $project, jobs => 1, undetected => 1, min_score => 100 );
is $api->assessment->{exitCode}, 1, 'the missed change fails the requested threshold in the API';
is [ map { [ $_->{mutant}->id, $_->{status} ] } $api->entries->@* ], [ [ $id, 'Survived' ] ],
  'the Perl API measures the same remaining gap';
write_file( "$project/t/positive.t", "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 1), 5;\n" );
ran( 0, $project, 'run', '--undetected', @options, '--format', 'json', '--min-score', 100 );
my $result =
  Test::Mutation::Report::Json::parse( Test::Mutation::Source::read_bytes("$project/mutation-report/mutation.json") );
is [ map { [ $_->{mutant}->id, $_->{status}, $_->{by}, $_->{tests_run} ] } $result->entries->@* ],
  [ [ $id, 'Killed', 't/positive.t', 2 ] ], 'only the saved gap runs and the new test confirms it twice';
is $result->assessment->{gate}, 'passed', 'the CLI stores the same gate that accepted the repaired test';
ok $result->selection->{undetected}, 'the report identifies a recheck of undetected mutants';
my $empty = ran( 0, $project, 'run', '--undetected', @options, '--min-score', 100 );
like $empty->{stdout},   qr/^0 mutants$/m, 'a repaired scope has zero mutants';
unlike $empty->{stderr}, qr/Baseline \(/,  'an empty recheck skips the test processes';

unlink "$project/t/positive.t" or die $!;
ran( 0, $project, 'run', @options );
write_file( "$project/lib/Totals.pm", "package Totals;\nsub sum { return 4 }\n1;\n" );
my $stale = ran( 2, $project, 'run', '--undetected', @options );
like $stale->{stderr}, qr/\Q$id\E.*mutation run lib\/Totals\.pm/,
  'a missing historical mutant names the file to measure';
unlike $stale->{stderr}, qr/Baseline \(/, 'a stale identifier is diagnosed before testing';

done_testing;
