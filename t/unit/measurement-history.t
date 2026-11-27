use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use Capability;
use lib 't/contract/lib';
use Samples;
use Test::Mutation::Settings;
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
my $narrow  = Test::Mutation::Result->new( $whole->%*, entries => [ $whole->entries->[0] ], finished => 105 );
my $changed = { $narrow->entries->[0]->%*, status => 'Killed', by => 't/verify.t' };
$narrow = Test::Mutation::Result->new( $narrow->%*, entries => [$changed] );
Test::Mutation::Store::History::record( $config, $narrow, 0 );
is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[1] ) ],
  'a verified kill clears that gap while leaving the other gap in the preceding scope';
my $empty = Test::Mutation::Result->new( $whole->%*, entries => [], finished => 106 );
Test::Mutation::Store::History::record( $config, $empty, 1 );
is Test::Mutation::Store::History::undetected($config), [], 'a completed empty scope is distinct from missing history';
my $merged =
  Test::Mutation::Result->new( $whole->%*, entries => [ $whole->entries->[0] ], started => 80, finished => 90 );
Test::Mutation::Store::History::record( $config, $merged, 1 );
is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[0] ) ],
  'merging older observed parts establishes the latest completed scope';
my $off = Test::Mutation::Settings::of_call( { root => $root, cache => 0 } );
is Test::Mutation::Store::History::undetected($off), undef, 'disabling the cache bypasses saved history';
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
    Test::Mutation::Store::History::record( $reader, $empty, 1 );
    is Test::Mutation::Store::History::undetected($reader), [], 'a private measurement supersedes the imported scope';
    chmod oct('755'), $root or die "chmod: $!";
    is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[0] ) ],
      'the checkout still holds the earlier scope';
};
done_testing;
