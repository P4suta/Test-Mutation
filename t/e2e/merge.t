use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of permutl run_fixture statuses);
use Test::Mutation::Report::Json;

my $root    = copy_of('calc');
my ($whole) = run_fixture($root);
my @parts   = map { ( run_fixture( $root, shard => "$_/2" ) )[0] } 1, 2;

subtest 'a result names its part and the mutants of the whole run' => sub {
    is $whole->shard,                undef,                         'a whole run has no part';
    is [ map { $_->shard } @parts ], [ '1/2', '2/2' ],              'a part names itself';
    is $whole->inventory->{mutants}, scalar( $whole->entries->@* ), 'the inventory counts every mutant';
    like $whole->inventory->{digest}, qr/\A[0-9a-f]{64}\z/, 'the inventory has a digest';
    is [ map { $_->inventory } @parts ], [ ( $whole->inventory ) x 2 ],
      'each part carries the inventory of the whole run';
};

sub slurp ($path) {
    open my $handle, '<:encoding(UTF-8)', $path or die "read $path: $!";
    local $/ = undef;
    return readline $handle;
}

my @options = ( '--format', 'json', '--format', 'terminal', '--jobs', 2 );
for my $part ( 1, 2 ) {
    my $run = permutl( $root, 'run', '--shard', "$part/2", '--report-dir', "part$part", @options );
    is $run->{exit}, 0, "part $part runs" or diag $run->{stderr};
}
my @reports = ( 'part2/mutation.json', 'part1/mutation.json' );

subtest 'the merge command reports the whole run from the reports of its parts' => sub {
    my $merge =
      permutl( $root, 'merge', @reports, '--report-dir', 'whole', '--format', 'json', '--format', 'terminal' );
    is $merge->{exit}, 0, 'exit status' or diag $merge->{stderr};
    my $merged = Test::Mutation::Report::Json::parse( slurp("$root/whole/mutation.json") );
    is statuses($merged),                      statuses($whole), 'every mutant has the status of the unsplit run';
    is [ $merged->shard, $merged->inventory ], [ undef, $whole->inventory ], 'the merged report is a whole run';
    my $tally = $whole->tally;
    like $merge->{stdout}, qr/^\Q$tally->{total}\E mutants: \Q$tally->{counts}{Killed}\E killed/m,
      'the terminal report counts the whole run';
    like $merge->{stdout}, qr{^Reports: whole/mutation\.json$}m, 'the report file is named';
};

subtest 'the merged score meets the threshold of a run' => sub {
    my $merge = permutl( $root, 'merge', @reports, '--min-score', 100, '--format', 'terminal' );
    is $merge->{exit}, 1, 'a score below the threshold fails';
};

subtest 'a set that is not one complete run is a usage error' => sub {
    my %refused = (
        'part 2 of 2 is missing'                                            => ['part1/mutation.json'],
        'part1/mutation.json and part1/mutation.json both hold part 1 of 2' => [ ('part1/mutation.json') x 2 ],
        'cannot read absent.json: No such file or directory'                => ['absent.json'],
        'lib/Calc.pm: the text is no JSON document'                         => ['lib/Calc.pm'],
        'merge needs the report of every part'                              => [],
    );
    for my $message ( sort keys %refused ) {
        my $merge = permutl( $root, 'merge', $refused{$message}->@*, '--report-dir', 'refused' );
        is [ $merge->{exit}, $merge->{stderr} ], [ 2, "permutl: $message\n" ], $message;
    }
    ok !-e "$root/refused", 'a refused merge writes no report';
};

done_testing;
