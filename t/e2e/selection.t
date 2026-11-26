use v5.36;
use Test2::V0;
use lib 't/e2e/lib', 't/lib';
use Capability;
use Test::Mutation ();
use Test::Mutation::Source;
use Fixture qw(copy_of run_fixture write_file);

# Selecting tests by line saves work, and it must never change which mutants the tests detect.

sub by_status ( $result, $status ) {
    return [ sort map { $_->{mutant}->id } grep { $_->{status} eq $status } $result->entries->@* ];
}

sub tests_run ($result) {
    my $total = 0;
    $total += $_->{tests_run} for $result->entries->@*;
    return $total;
}

# Every fixture takes part, so a new one joins the comparison without an edit here.
opendir my $directory, 't/fixtures' or die "read t/fixtures: $!";
my @fixtures = sort grep { !/\A[.]/ } readdir $directory;
closedir $directory or die "close t/fixtures: $!";
is \@fixtures, [qw(calc counter equivalent exclusive mechanics realworld script)], 'the fixtures';

for my $fixture (@fixtures) {
    next
      if $fixture eq 'counter'
      && !Capability::has( 'class', $] >= 5.038, 'the fixture needs the class syntax of Perl 5.38' );
    subtest $fixture => sub {
        my $root = copy_of($fixture);
        my %result;
        my @endless =
          $fixture eq 'mechanics'
          ? ( 'lib/Loop.pm:9 removed the statement', 'lib/Loop.pm:9 replaced -- with ++' )
          : ();
        for my $mode (qw(line file)) {
            ( $result{$mode} ) = run_fixture( $root, coverage => $mode );
            is $result{$mode}->baseline_failures, [], "$mode: the unmodified run passes";
            my $observed = Fixture::statuses( $result{$mode} );
            is [ sort grep { $observed->{$_} eq 'Timeout' } keys %$observed ], \@endless,
              "$mode: only nonterminating loops reach the test deadline";
        }
        for my $status (qw(Killed Timeout CompileError)) {
            is by_status( $result{line}, $status ), by_status( $result{file}, $status ), "the same mutants are $status";
        }
        my %undetected_by_file = map { $_ => 1 } by_status( $result{file}, 'Survived' )->@*,
          by_status( $result{file}, 'NoCoverage' )->@*;
        my @extra = grep { !$undetected_by_file{$_} } by_status( $result{line}, 'Survived' )->@*,
          by_status( $result{line}, 'NoCoverage' )->@*;
        is \@extra, [], 'every mutant that line selection leaves undetected is undetected by file selection';
        ok tests_run( $result{line} ) <= tests_run( $result{file} ), 'line selection runs no more tests';
    };
}

subtest 'a test omitted from the distribution target still belongs to a recursive run' => sub {
    my $root = copy_of('realworld');
    my ($curated) = run_fixture($root);
    is $curated->baseline_failures, [], 'the selected distribution tests pass';
    ok @{ $curated->entries }, 'the passing baseline measures its source';
    my ($recursive) = run_fixture( $root, test_exclude => [] );
    is [ map { $_->{test} } @{ $recursive->baseline_failures } ], ['t/archive/count.t'],
      'the failing independent test is named exactly';
    is $recursive->tally->{valid}, 0, 'the failing baseline supplies no score';
};

subtest 'a successful load-time probe can become a compile-phase exception' => sub {
    my $root   = copy_of('realworld');
    my $source = 'lib/CompileDuringLoad.pm';
    write_file( "$root/$source", Test::Mutation::Source::read_bytes('t/corpus/findings/CompileDuringLoad.pm') );
    write_file( "$root/t/load.t",
        "use Test::More tests => 1;\nuse CompileDuringLoad;\nok CompileDuringLoad::available(), 'load completed';\n" );
    my %only = ( root => $root, source => [$source], test => ['t/load.t'], test_exclude => [] );
    my ($logical) = grep { $_->original eq 'or' } @{ Test::Mutation::mutants(%only) };
    ok $logical, 'the logical operator in the successful probe can change' or return;
    my ($result) = run_fixture( $root, %only, mutant => [ $logical->id ] );
    my ($entry)  = @{ $result->entries };
    is [ $entry->{mutant}->id, $entry->{status}, $entry->{reason} ], [ $logical->id, 'CompileError', 'compile-phase' ],
      'the compile-time exception retains its cause and identifier';
};

done_testing;
