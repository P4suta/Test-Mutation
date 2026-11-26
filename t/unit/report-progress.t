use v5.36;
use Test2::V0;
use Test::Mutation::Report::Progress;
use Test::Mutation::Status;

subtest 'line shows the position and the counts that matter' => sub {
    is Test::Mutation::Report::Progress::line( 7, 19, { Killed => 4, Survived => 2, NoCoverage => 1 } ),
      '[ 7/19] 4 killed, 2 survived, 1 no coverage', 'counts in a fixed order, position padded to the total';
    is Test::Mutation::Report::Progress::line( 19, 19, { Killed => 13, Survived => 3, NoCoverage => 3, Timeout => 0 } ),
      '[19/19] 13 killed, 3 survived, 3 no coverage', 'zero counts are left out';
    is Test::Mutation::Report::Progress::line( 1, 1200, { Timeout => 1 } ), '[   1/1200] 1 timeout', 'a wide total';
    is Test::Mutation::Report::Progress::line( 0, 5,    {} ),               '[0/5]', 'nothing counted yet';
    is Test::Mutation::Report::Progress::line( 8, 8,    { map { $_ => 1 } Test::Mutation::Status::names()->@* } ),
      '[8/8] 1 killed, 1 survived, 1 no coverage, 1 timeout, 1 compile error, 1 no verdict, 1 ignored, 1 pending',
      'the statuses that the catalog counts in the progress line, in its order';
};

subtest 'due tells when a line belongs in a log' => sub {
    my @due = grep { Test::Mutation::Report::Progress::due( $_, 200 ) } 1 .. 200;
    is \@due, [ map { $_ * 20 } 1 .. 10 ],                                             'every tenth of a large run';
    is [ grep { Test::Mutation::Report::Progress::due( $_, 7 ) } 1 .. 7 ], [ 1 .. 7 ], 'every mutant of a small run';
    ok Test::Mutation::Report::Progress::due( 1234, 1234 ), 'the last mutant';
};

subtest 'update gives the text for a terminal or for a log' => sub {
    my $update =
      sub ( $done, $in_place ) { Test::Mutation::Report::Progress::update( $done, 30, { Killed => $done }, $in_place ) };
    is $update->( 4,  1 ), "\r[ 4/30] 4 killed",    'a terminal overwrites its line';
    is $update->( 30, 1 ), "\r[30/30] 30 killed\n", 'and ends the line after the last mutant';
    is $update->( 4,  0 ), q{},                     'a log skips a mutant between two steps';
    is $update->( 6,  0 ), "[ 6/30] 6 killed\n",    'and gets a line at a step';
    is $update->( 30, 0 ), "[30/30] 30 killed\n",   'and at the last mutant';
};

done_testing;
