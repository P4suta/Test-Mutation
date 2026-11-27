use v5.36;
use Test2::V0;
use DBI;
use File::Temp ();
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
done_testing;
