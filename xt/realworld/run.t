use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/lib';
use Gate;
use RealWorld;

# The release gate reads the records of a run of the tool on real distributions.
# `mise run realworld` writes the records inside a container and then runs this file.
# A record outside the expectation of its run is a finding, and the open findings name the ones that a slice removes.

my $TABLE   = 'xt/realworld/distributions.toml';
my $RECORDS = 'mutation-report/realworld.jsonl';

sub slurp ($path) {
    open my $handle, '<:raw', $path or die "read $path: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return $text;
}

subtest 'the gate rejects a run without a record and a record of another archive' => sub {
    my ($run) = RealWorld::runs(<<'TOML')->@*;
[Example]
name = "Example"
version = "1.0"
pathname = "A/AU/AUTHOR/Example-1.0.tar.gz"
sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
shape = "pure Perl"
tests = ["prove", "-lr", "t"]

[Example.expect]
mutants = [4, 4]
score = [70, 80]
warnings = []
seconds = 60
TOML
    my $record = {
        run      => 'Example',
        sha256   => $run->{sha256},
        tests    => { exit => 0, files   => 2 },
        prove    => { exit => 0, files   => 2 },
        mutation => { exit => 0, seconds => 2, limit => 0, stderr => ['4 mutants in 1 file, 2 tests'] },
        report   => {
            warnings          => [],
            skipped           => [],
            baseline_failures => [],
            mutants           => [ map { { status => $_ } } qw(Killed Killed Killed Survived) ],
        },
    };
    my $at = sub ($records) {
        return Gate::outcomes(
            sub { Gate::findings( 'realworld', RealWorld::judged( [$run], $records ), file => '/dev/null' ) } );
    };
    is $at->( { Example => $record } ), [ 'pass', 'pass' ], 'a record inside the expectation of its run passes';
    is $at->( {} ),                     [ 'fail', 'pass' ], 'a run without a record fails';
    is $at->( { Example => { $record->%*, sha256 => 'b' x 64 } } ), [ 'fail', 'pass' ],
      'a record of another archive fails';
    is $at->( { Example => $record, Other => $record } ), [ 'fail', 'pass' ],
      'a record that names no run of the table fails';
};

my $runs    = RealWorld::runs( slurp($TABLE) );
my $records = -e $RECORDS ? RealWorld::records( slurp($RECORDS) ) : {};
diag "no records at $RECORDS: `mise run realworld` writes them" if !-e $RECORDS;

for my $run ( $runs->@* ) {
    my $record = $records->{ $run->{run} } or next;
    note "$run->{run}: " . RealWorld::summary($record);
    note "$run->{run}: $_" for RealWorld::notes( $run, $record )->@*;
}
Gate::findings( 'realworld', RealWorld::judged( $runs, $records ) );
Gate::checked( 'runs with a record', scalar( grep { $records->{ $_->{run} } } $runs->@* ), at_least => 11 );

done_testing;
