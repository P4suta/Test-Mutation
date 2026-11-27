use v5.36;
use Test2::V0;
use DBI;
use File::Temp ();
use lib 't/lib';
use Capability;
use Test::Mutation::Settings;
use Test::Mutation::Store;

my $directory = File::Temp::tempdir( CLEANUP => 1 );
my $database  = "$directory/measurement.sqlite";
my $record    = {
    inputs    => 'input',
    path      => 'lib/Sum.pm',
    source    => 'source',
    status    => 'Survived',
    reason    => undef,
    detail    => undef,
    by        => undef,
    tests_run => 1,
    duration  => 1,
    code      => undef
};
Test::Mutation::Store::save( "$directory/cache.json", { first  => $record } );
Test::Mutation::Store::save( $database,               { second => $record } );
is Test::Mutation::Store::load($database), { first => $record, second => $record },
  'the new store imports compatible JSON verdicts before adding its own';
my $db = DBI->connect( "dbi:SQLite:dbname=$database", undef, undef, { RaiseError => 1, PrintError => 0 } );
is $db->selectcol_arrayref('SELECT id FROM verdict ORDER BY id'), [qw(first second)],
  'the driver persists a separately addressable row for each verdict';
subtest 'measurements in a read-only checkout' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can write to read-only directories' );
    my $read_only = File::Temp::tempdir( CLEANUP => 1 );
    my $config    = Test::Mutation::Settings::of_call( { root => $read_only } );
    chmod oct('555'), $read_only or die "chmod: $!";
    my $private = Test::Mutation::Store::path($config);
    chmod oct('755'), $read_only or die "chmod: $!";
    ok index( $private, "$read_only/" ) != 0, 'a read-only project uses a private database outside the checkout';
    is Test::Mutation::Store::path($config), $private, 'the configuration keeps its private database for the whole run';
};
done_testing;
