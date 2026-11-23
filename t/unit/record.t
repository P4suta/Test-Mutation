use v5.36;
use Test2::V0;
use File::Temp ();
use Permutl::Record;

sub lines (@rows) {
    return join q{}, map { join( "\t", $_->@* ) . "\n" } @rows;
}

subtest 'a traced process' => sub {
    my $record = Permutl::Record::parse(
        [
            lines(
                [ 'begin',  1 ],
                [ 'served', '/p/lib/A.pm' ],
                [ 'hit',    '/p/lib/A.pm', 3 ],
                [ 'hit',    '/p/lib/A.pm', 7 ],
                [ 'lines',  '/p/lib/A.pm', '3,5,7' ],
                [ 'end',    4242 ],
            )
        ]
    );
    is $record->{served}, { '/p/lib/A.pm' => { traced => 1, hits => { 3 => 1, 7 => 1 } } }, 'served file with its hits';
    is $record->{breakable},   { '/p/lib/A.pm' => { 3 => 1, 5 => 1, 7 => 1 } },             'breakable lines';
    is $record->{load_failed}, {},                                                          'no load failure';
    is $record->{bypassed},    {},                                                          'no bypass';
};

subtest 'load failures, bypasses, and errors' => sub {
    my $record = Permutl::Record::parse(
        [
            lines(
                [ 'begin',    0 ],
                [ 'served',   '/p/A.pm' ],
                [ 'loadfail', '/p/A.pm' ],
                [ 'bypass',   '/p/B.pm' ],
                [ 'error',    '/p/C.pm', 'cannot open' ],
                [ 'error',    '/p/D.pm', 'cannot read' ],
            )
        ]
    );
    is $record->{load_failed}, { '/p/A.pm' => 1 }, 'load failure';
    is $record->{bypassed},    { '/p/B.pm' => 1 }, 'bypass';
    is $record->{errors}, [ '/p/C.pm: cannot open', '/p/D.pm: cannot read' ], 'errors in the order of the record';
    is $record->{served}{'/p/A.pm'}{traced}, 0, 'an untraced process marks the file as untraced';
};

subtest 'several processes of one test run' => sub {
    my $traced   = lines( [ 'begin', 1 ], [ 'served', '/p/A.pm' ], [ 'hit', '/p/A.pm', 2 ] );
    my $untraced = lines( [ 'begin', 0 ], [ 'served', '/p/A.pm' ] );
    my $other    = lines( [ 'begin', 1 ], [ 'served', '/p/B.pm' ], [ 'hit', '/p/B.pm', 9 ] );
    is Permutl::Record::parse( [ $traced, $other ] )->{served},
      { '/p/A.pm' => { traced => 1, hits => { 2 => 1 } }, '/p/B.pm' => { traced => 1, hits => { 9 => 1 } } },
      'files of different processes are merged';
    is Permutl::Record::parse( [ $traced, $untraced ] )->{served}{'/p/A.pm'}, { traced => 0, hits => { 2 => 1 } },
      'one untraced process makes the file untraced';
    is Permutl::Record::parse( [ $untraced, $traced ] )->{served}{'/p/A.pm'}{traced}, 0, 'whatever the order';
};

subtest 'unknown and malformed lines are ignored' => sub {
    my $record = Permutl::Record::parse( ["begin\t1\nmystery\t/p/A.pm\nserved\n\nhit\t/p/A.pm\n"] );
    is $record, { served => {}, compiled => {}, load_failed => {}, bypassed => {}, breakable => {}, errors => [] },
      'an unknown kind, a line without a path, and a hit without a line number leave nothing';
    is Permutl::Record::parse( [] )->{served}, {}, 'no record files';

    my $after = Permutl::Record::parse( ["begin\t1\nserved\nbypass\t/p/A.pm\nmystery\t/p/B.pm\nloadfail\t/p/C.pm\n"] );
    is [ $after->{bypassed}, $after->{load_failed} ], [ { '/p/A.pm' => 1 }, { '/p/C.pm' => 1 } ],
      'the lines after a malformed line and after an unknown kind still count';
};

subtest 'a compiled line marks a target that compiled' => sub {
    my $record = Permutl::Record::parse(
        [ lines( [ 'begin', 0 ], [ 'served', '/p/A.pm' ], [ 'compiled', '/p/A.pm' ], [ 'served', '/p/B.pm' ] ) ] );
    is $record->{compiled}, { '/p/A.pm' => 1 }, 'the compiled target, without the one that failed';
};

subtest 'read_directory reads every record file' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    for my $file (
        [ 'one.rec',  lines( [ 'begin', 1 ], [ 'served', '/p/A.pm' ], [ 'error', '/p/A.pm', 'first' ] ) ],
        [ 'two.rec',  lines( [ 'begin', 1 ], [ 'bypass', '/p/B.pm' ], [ 'error', '/p/B.pm', 'second' ] ) ],
        [ 'note.txt', 'served' ]
      )
    {
        open my $handle, '>', "$directory/$file->[0]" or die "open: $!";
        print {$handle} $file->[1] or die "print: $!";
        close $handle              or die "close: $!";
    }
    my $record = Permutl::Record::read_directory($directory);
    is [ sort keys $record->{served}->%* ],   ['/p/A.pm'],         'served';
    is [ sort keys $record->{bypassed}->%* ], ['/p/B.pm'],         'bypassed';
    is $record->{errors}, [ '/p/A.pm: first', '/p/B.pm: second' ], 'the errors follow the names of the files';
};

done_testing;
