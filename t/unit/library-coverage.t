use v5.36;
use Test2::V0;
use lib 'xt/lib';
use LibraryCoverage;

my $floors = { statement => [ 7,  9 ],  branch => [ 2, 3 ] };
my $counts = { statement => [ 14, 18 ], branch => [ 4, 6 ] };
is LibraryCoverage::findings( $counts, $floors ), [], 'both exact fractions can meet their floors';
is LibraryCoverage::findings( { %$counts, statement => [ 13, 17 ] }, $floors ),
  ['statement coverage 13/17 is below 7/9'], 'a statement regression cannot hide behind branch coverage';
is LibraryCoverage::findings( { %$counts, branch => [ 19999, 30000 ] }, $floors ),
  ['branch coverage 19999/30000 is below 2/3'], 'rounding the percentage cannot hide a branch regression';
is LibraryCoverage::findings( { statement => [ 0, 0 ], branch => [ 0, 0 ] }, $floors ),
  [ 'statement coverage has no observations', 'branch coverage has no observations' ],
  'an empty measurement cannot pass';

my @rows = ( "statement\t7\t9\n", "branch\t2\t3\n" );
is LibraryCoverage::floors( [ reverse @rows ] ), $floors,
  'the release table keeps separate exact fractions in any order';
is LibraryCoverage::floors( [ "branch\t0\t1", "statement\t9\t9" ] ),
  { branch => [ 0, 1 ], statement => [ 9, 9 ] }, 'committed floors can include zero or all observed locations';
for my $case (
    [ [],                  qr/missing statement/ ],
    [ [ $rows[0] ],        qr/missing branch/ ],
    [ [ @rows, $rows[0] ], qr/duplicate statement/ ],
    (
        map { [ [ @rows, $_ ], qr/invalid coverage floor/ ] } "line\t1\t2",
        "branch\t2\t1", "branch\t0\t0", "branch\t-1\t2", "branch\t1.0\t2", "statement\t1\t2\textra"
    )
  )
{
    like dies { LibraryCoverage::floors( $case->[0] ) }, $case->[1], 'malformed or incomplete release floors fail';
}

my $files = [qw(lib/One.pm lib/Deep/Two.pm)];
is LibraryCoverage::sources( $files, [qw(t/tests.t lib/Deep/Two.pm /repo/lib/One.pm)], '/repo' ),
  [qw(/repo/lib/One.pm lib/Deep/Two.pm)], 'the report counts each project module under its measured path';
like dies { LibraryCoverage::sources( $files, [ 'lib/One.pm', '/elsewhere/lib/Deep/Two.pm' ], '/repo' ) },
  qr/missing.*lib\/Deep\/Two[.]pm/, 'a measurement of another checkout cannot stand in for an unmeasured source';
like dies { LibraryCoverage::sources( $files, [ @$files, '/repo/lib/One.pm' ], '/repo' ) },
  qr/duplicate.*lib\/One[.]pm/,
  'two databases for the same source cannot inflate the total';
done_testing;
