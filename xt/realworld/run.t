use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/lib';
use Gate;
use RealWorld;
use Test::Mutation::Mutator::Catalog;

# The release gate reads the records of a run of the tool on real distributions.
# `mise run realworld` writes the records inside a container and then runs this file.

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
        return Gate::outcomes( sub { Gate::findings( 'realworld', RealWorld::judged( [$run], $records ) ) } );
    };
    is $at->( { Example => $record } ), ['pass'], 'a record inside the expectation of its run passes';
    is $at->( {} ),                     ['fail'], 'a run without a record fails';
    is $at->( { Example => { $record->%*, sha256 => 'b' x 64 } } ), ['fail'], 'a record of another archive fails';
    is $at->( { Example => $record, Other => $record } ), ['fail'], 'a record that names no run of the table fails';
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
for my $case ( [ 'Moo', '24aa5ed551a7', 'lib/Moo/_Utils.pm' ],
    [ 'Variable-Magic', '5ebd8caa0236', 'lib/Variable/Magic.pm' ] )
{
    my ( $name, $id, $file ) = @$case;
    my $probe = $records->{$name}{compile_probe};
    is $probe->{exit}, 0, "$name completes a narrowed measurement with no eligible mutant";
    is [ map { [ $_->@{qw(id file status reason)} ] } @{ $probe->{mutants} || [] } ],
      [ [ $id, $file, 'CompileError', 'compile-phase' ] ],
      "$name preserves the compile-time exception by ID in any shard";
}
my $loads = RealWorld::load_counts( $runs, $records );
note "$_: $loads->{$_}[0] failed loads in $loads->{$_}[1] probes" for sort keys $loads->%*;
my @defaults = map { $_->name } grep { $_->profile eq 'default' } Test::Mutation::Mutator::Catalog::mutators()->@*;
is RealWorld::load_findings( $loads, \@defaults ), [], 'the default mutators load in at least 90 percent of probes';
Gate::checked( 'runs with a record', scalar( grep { $records->{ $_->{run} } } $runs->@* ), at_least => 11 );

done_testing;
