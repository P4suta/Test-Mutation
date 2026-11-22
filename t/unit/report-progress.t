use v5.36;
use Test2::V0;
use Permutl::Report::Progress;

subtest 'line shows the position and the counts that matter' => sub {
    is Permutl::Report::Progress::line( 7, 19, { Killed => 4, Survived => 2, NoCoverage => 1 } ),
      '[ 7/19] 4 killed, 2 survived, 1 no coverage', 'counts in a fixed order, position padded to the total';
    is Permutl::Report::Progress::line( 19, 19, { Killed => 13, Survived => 3, NoCoverage => 3, Timeout => 0 } ),
      '[19/19] 13 killed, 3 survived, 3 no coverage', 'zero counts are left out';
    is Permutl::Report::Progress::line( 1, 1200, { Timeout => 1 } ), '[   1/1200] 1 timeout', 'a wide total';
    is Permutl::Report::Progress::line( 0, 5,    {} ),               '[0/5]',                 'nothing counted yet';
};

subtest 'due tells when a line belongs in a log' => sub {
    my @due = grep { Permutl::Report::Progress::due( $_, 200 ) } 1 .. 200;
    is \@due, [ map { $_ * 20 } 1 .. 10 ],                                      'every tenth of a large run';
    is [ grep { Permutl::Report::Progress::due( $_, 7 ) } 1 .. 7 ], [ 1 .. 7 ], 'every mutant of a small run';
    ok Permutl::Report::Progress::due( 1234, 1234 ), 'the last mutant';
};

done_testing;
