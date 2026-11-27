use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use Capability;
use lib 't/contract/lib';
use Samples;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Store::History;
use Test::Mutation::Store::Key;

my $root   = File::Temp::tempdir( CLEANUP => 1 );
my $config = Test::Mutation::Settings::of_call( { root => $root, cache => 1 } );
my $whole  = Samples::result( statuses => [qw(Survived NoCoverage Killed)] );
is Test::Mutation::Store::History::undetected($config), undef, 'a project has no completed measurement yet';
Test::Mutation::Store::History::record( $config, $whole, 1 );
my $gap = sub ($entry) {
    my $mutant = $entry->{mutant};
    return {
        id     => $mutant->id,
        path   => $mutant->path,
        source => Test::Mutation::Store::Key::digest( $whole->sources->{ $mutant->path } )
    };
};
is Test::Mutation::Store::History::undetected($config), [ map { $gap->($_) } $whole->entries->@[ 0, 1 ] ],
  'the latest completed scope yields only its undetected mutants in inventory order';
my $uncertain = Samples::result( statuses => [qw(NoVerdict Timeout NoVerdict)], finished => 104 );
Test::Mutation::Store::History::record( $config, $uncertain, 0 );
is Test::Mutation::Store::History::undetected($config), [ map { $gap->($_) } $whole->entries->@[ 0, 1 ] ],
  'inconclusive rechecks preserve known gaps and leave a confirmed detection closed';
my $first   = $whole->entries->[0]{mutant};
my $file    = $first->path;
my $source  = Test::Mutation::Source->from_bytes( path => $file, bytes => $whole->sources->{$file} );
my $history = Test::Mutation::Store::History::entries( $config, { $file => $source }, [$first] );
is $history->{ $first->id }{status}, 'NoVerdict', 'the latest inconclusive observation is available for inspection';
my $narrow  = Test::Mutation::Result->new( $whole->%*, entries => [ $whole->entries->[0] ], finished => 105 );
my $changed = { $narrow->entries->[0]->%*, status => 'Killed', by => 't/verify.t' };
$narrow = Test::Mutation::Result->new( $narrow->%*, entries => [$changed] );
Test::Mutation::Store::History::record( $config, $narrow, 0 );
is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[1] ) ],
  'a verified kill clears that gap while leaving the other gap in the preceding scope';
my $delayed = Test::Mutation::Result->new( $whole->%*, entries => [ $whole->entries->[0] ], finished => 103 );
Test::Mutation::Store::History::record( $config, $delayed, 0 );
is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[1] ) ],
  'an earlier verification published late cannot reopen a more recently detected gap';
my $empty = Test::Mutation::Result->new( $whole->%*, entries => [], finished => 106 );
Test::Mutation::Store::History::record( $config, $empty, 1 );
is Test::Mutation::Store::History::undetected($config), [], 'a completed empty scope is distinct from missing history';
my $merged =
  Test::Mutation::Result->new( $whole->%*, entries => [ $whole->entries->[0] ], started => 80, finished => 90 );
my $merged_at = { completed => 107, measured => { $first->id => $merged->finished } };
Test::Mutation::Store::History::record( $config, $merged, 1, $merged_at );
is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[0] ) ],
  'merging older observed parts establishes the latest completed scope';
is Test::Mutation::Store::History::entries( $config, { $file => $source }, [$first] )->{ $first->id }{finished}, 105,
  'merging an older shard preserves the date of the newer individual observation';

subtest 'a merge keeps the finish time of each part for inspection' => sub {
    my $other   = Test::Mutation::Settings::of_call( { root => File::Temp::tempdir( CLEANUP => 1 ) } );
    my @mutants = map { $_->{mutant} } $whole->entries->@*;
    my %dates   = map { $mutants[$_]->id => 89 + $_ / 2 } keys @mutants;
    Test::Mutation::Store::History::record( $other, $whole, 1, { completed => 108, measured => \%dates } );
    my $saved = Test::Mutation::Store::History::entries( $other, { $file => $source }, \@mutants );
    is {
        map { $_ => $saved->{$_}{finished} } keys %$saved
    }, \%dates, 'each inspected mutant dates from its own shard';
};
my $off = Test::Mutation::Settings::of_call( { root => $root, cache => 0 } );
is Test::Mutation::Store::History::undetected($off), undef, 'disabling the cache bypasses saved history';
subtest 'history follows finish times when concurrent writers commit out of order' => sub {
    my $other  = Test::Mutation::Settings::of_call( { root => File::Temp::tempdir( CLEANUP => 1 ) } );
    my $record = sub ( $finished, $entries, $anchor ) {
        my $result = Test::Mutation::Result->new( $whole->%*, entries => $entries, finished => $finished );
        Test::Mutation::Store::History::record( $other, $result, $anchor );
    };
    my $gaps = sub { Test::Mutation::Store::History::undetected($other) };
    $record->( 120, [$changed],      0 );
    $record->( 110, $whole->entries, 1 );
    is $gaps->(), [ $gap->( $whole->entries->[1] ) ], 'a later detection can commit before its scope';
    $record->( 108, [], 1 );
    is $gaps->(), [ $gap->( $whole->entries->[1] ) ], 'a late write with an older finish cannot replace the scope';
    $record->( 130, [ $whole->entries->[0] ],     0 );
    $record->( 130, [ $uncertain->entries->[0] ], 1 );
    is $gaps->(), [], 'an inconclusive scope excludes the earlier write with the same finish';
    $record->( 129.5, [ $whole->entries->[0] ], 0 );
    is $gaps->(), [], 'a late observation from before the scope cannot open a gap';
    $record->( 130, [ $whole->entries->[0] ], 0 );
    is $gaps->(), [ $gap->( $whole->entries->[0] ) ], 'the next write with the same finish can open a gap';
    $record->( 130, [], 1 );
    is $gaps->(), [], 'recording another scope with the same finish breaks the tie';
};

subtest 'read-only history stays available and fresh observations are private' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can write to read-only directories' );
    chmod oct('555'), $root or die "chmod: $!";
    my $reader = Test::Mutation::Settings::of_call( { root => $root } );
    is Test::Mutation::Store::History::undetected($reader), [ $gap->( $whole->entries->[0] ) ],
      'a query reads the existing history in the checkout';
    my $private = Test::Mutation::Store::path($reader);
    ok -f $private, 'the private writer starts from a snapshot of the indexed checkout';
    is Test::Mutation::Store::History::undetected($reader), [ $gap->( $whole->entries->[0] ) ],
      'the private snapshot includes the completed scope';
    Test::Mutation::Store::History::record( $reader, Test::Mutation::Result->new( $empty->%*, finished => 108 ), 1 );
    is Test::Mutation::Store::History::undetected($reader), [], 'a private measurement supersedes the imported scope';
    chmod oct('755'), $root or die "chmod: $!";
    is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[0] ) ],
      'the checkout still holds the earlier scope';
};
done_testing;
