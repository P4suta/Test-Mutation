use v5.36;
use Test2::V0;
use Cwd        ();
use Encode     ();
use File::Temp ();
use lib 'xt/lib', 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use SelfMeasurement;
use Test::Mutation::Report::Json;
use Test::Mutation::Result;
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
write_file( "$root/lib/Addition.pm", "package Addition;\nsub sum { return \$_[0] + \$_[1] }\n1;\n" );
write_file( "$root/lib/Empty.pm",    "package Empty;\n1;\n" );
write_file( "$root/t/add.t",         "use Test::More tests => 1;\nuse Addition;\nis Addition::sum(2, 3), 5;\n" );
my $config    = Test::Mutation::Settings::of_call( { root => $root, jobs => 1 } );
my $selection = Test::Mutation::Select::resolve( config => $config );
my ($clean)   = run_fixture( $root, jobs => 1 );
sub changed  (%fields) { return Test::Mutation::Result->new( $clean->%*, %fields ) }
sub findings ($result) { return SelfMeasurement::findings( $result, $selection ) }
is findings($clean), [], 'a complete passing measurement includes an analyzed file with no mutant';

subtest 'the release requires freshly measured verdicts' => sub {
    my ($warm) = run_fixture( $root, jobs => 1 );
    ok $warm->reused > 0, 'the repeated measurement reads verdicts from the cache';
    is $warm->tally->{score}, 100, 'the cached verdicts still produce a perfect score';
    like findings($warm), bag { item qr/cached verdicts/; etc }, 'the report records the previous run as its source';
};

subtest 'the release reads the saved UTF-8 report before checking the measurement' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    my $path      = "$directory/mutation.json";
    my $warning   = "case \x{96ea}";
    my $json      = Test::Mutation::Report::Json::render( changed( warnings => [$warning] ), high => 80, low => 60 );
    write_file( $path, Encode::encode( 'UTF-8', $json ) );
    my $report = SelfMeasurement::read_report($path);
    is $report->warnings, [$warning], 'the saved report decodes its text as UTF-8';
    is findings($report), [],         'the serialized inventory and verdicts pass the same release checks';
    write_file( $path, '{}' );
    ok dies { SelfMeasurement::read_report($path) }, 'an incomplete report cannot stand in for a measurement';
    unlink $path or die "remove the sample report: $!";
    like dies { SelfMeasurement::read_report($path) }, qr/\Aread \Q$path\E: /,
      'the diagnostic names the report that could not be opened for reading';
};

my ( $first, @rest ) = $clean->entries->@*;
my $id = $first->{mutant}->id;
for my $pair (
    [ 'Survived',     undef ],
    [ 'NoCoverage',   'unreached' ],
    [ 'Timeout',      'time-limit' ],
    [ 'NoVerdict',    'unstable-test' ],
    [ 'Pending',      'interrupted' ],
    [ 'CompileError', 'parse' ],
  )
{
    my ( $status, $reason ) = @$pair;
    my $entry = { $first->%*, status => $status, reason => $reason };
    like findings( changed( entries => [ $entry, @rest ] ) ), bag { item qr/\Q$id\E.*\Q$status\E/; etc },
      "the release refuses $status for the reported mutant";
}
for my $case (
    [ { catalog_digest    => undef },                                                                  qr/catalog/ ],
    [ { catalog_digest    => 'other' },                                                                qr/catalog/ ],
    [ { inventory         => undef },                                                                  qr/inventory/ ],
    [ { inventory         => { $clean->inventory->%*, mutants => $clean->inventory->{mutants} + 1 } }, qr/inventory/ ],
    [ { inventory         => { $clean->inventory->%*, digest => '0' x 64 } },                          qr/inventory/ ],
    [ { entries           => [@rest] },                                                       qr/mutant inventory/ ],
    [ { entries           => [ $first, $first, @rest ] },                                     qr/mutant inventory/ ],
    [ { sources           => { 'lib/Addition.pm' => $clean->sources->{'lib/Addition.pm'} } }, qr/Empty[.]pm/ ],
    [ { sources           => { $clean->sources->%*, 'lib/Empty.pm' => "0;\n" } },             qr/Empty[.]pm/ ],
    [ { problems          => [ { path => 'lib/Bad.pm', problem => 'parse failed' } ] },       qr/Bad[.]pm/ ],
    [ { baseline_failures => [ { test => 't/add.t', output => 'not ok', errors => q{} } ] },  qr/t\/add[.]t/ ],
    [ { interrupted       => 'TERM' },                                                        qr/TERM/ ],
    [ { cache_mismatch    => 1 },                                                             qr/cache/ ],
    [ { shard             => '1/2' },                                                         qr/whole/ ],
    [ { selection         => { since => 'HEAD' } },                                           qr/whole/ ],
    [ { entries           => [] },                                                            qr/score/ ],
  )
{
    like findings( changed( $case->[0]->%* ) ), bag { item $case->[1]; etc }, 'the gate identifies the incomplete fact';
}
for my $cause (qw(compile-phase standalone)) {
    my $entry = { %$first, status => 'CompileError', reason => $cause };
    is findings( changed( entries => [ $entry, @rest ] ) ), [],
      "a valid mutant that fails compilation for $cause leaves the measured score intact";
}
my $survivor = { %$first, status => 'Survived', reason => undef };
is findings( changed( entries => [ $survivor, @rest ] ) ),
  [ "$id: Survived", 'the full mutation score must reach 100%' ],
  'a defined score below 100 fails the threshold as well as the verdict check';
for my $reason (qw(same-code-as-original same-code-as-mutant)) {
    my $ignored = { %$first, status => 'Ignored', reason => $reason };
    unlike join( "\n", findings( changed( entries => [ $ignored, @rest ] ) )->@* ), qr/\Q$id\E:.*suppression/,
      'compiler equivalence does not require a source directive';
}

my $unsupported = { %$first, status => 'Ignored', reason => 'suppressed' };
like findings( changed( entries => [ $unsupported, @rest ] ) ), bag { item qr/\Q$id\E:.*suppression/; etc },
  'a report cannot invent a suppression in the current source';
my $with_source = $clean->sources->{'lib/Addition.pm'};
$with_source =~ s/(sub sum [^\n]+)/$1    ## no mutate (arithmetic): the addition follows a fixed protocol/;
write_file( "$root/lib/Addition.pm", $with_source );
my $strict = Test::Mutation::Settings::of_call(
    { root => $root, jobs => 1, suppress_require_names => 1, suppress_require_reason => 1 } );
my $suppressed = Test::Mutation::Select::resolve( config => $strict );
my ($observed) = run_fixture( $root, jobs => 1, suppress_require_names => 1, suppress_require_reason => 1 );
is SelfMeasurement::findings( $observed, $suppressed ), [], 'a used named directive with its source reason passes';
my @forged =
  map { $_->{mutant}->suppressed ? { %$_, status => 'Killed', reason => undef } : $_ } $observed->entries->@*;
like SelfMeasurement::findings( Test::Mutation::Result->new( %$observed, entries => \@forged ), $suppressed ),
  bag { item qr/suppression/; etc }, 'a detector cannot claim a mutant that the source suppresses';
done_testing;
