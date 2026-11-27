use v5.36;
use Test2::V0;
use DBI;
use File::Temp ();
use POSIX      ();
use lib 't/lib';
use Capability;
use Test::Mutation::Settings;
use Test::Mutation::Store;

my $directory = File::Temp::tempdir( CLEANUP => 1 );
my $database  = "$directory/measurement.sqlite";
subtest 'an empty lookup leaves the project tree untouched' => sub {
    my $missing = "$directory/absent/measurement.sqlite";
    is Test::Mutation::Store::load($missing),      {},                           'a new checkout has no saved verdicts';
    is Test::Mutation::Store::originals($missing), { build => [], tests => {} }, 'the baseline lookup is empty';
    ok !-e "$directory/absent", 'looking for reusable records creates no directory';
};
my $record = {
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
subtest 'cache paths preserve filename punctuation' => sub {
    my $literal = "$directory/cache;name=100%24?#/measurement.sqlite";
    Test::Mutation::Store::save( $literal, { punctuated => $record } );
    ok -f $literal, 'the database occupies the complete requested path';
    is Test::Mutation::Store::load($literal), { punctuated => $record }, 'the requested database contains the verdict';
};

subtest 'an unreadable cached verdict is measured again without losing its neighbors' => sub {
    my $path = "$directory/damaged/measurement.sqlite";
    Test::Mutation::Store::save( $path, { map { $_ => $record } qw(ambiguous broken missing intact) } );
    my $connection = Test::Mutation::Store::database($path);
    $connection->do(
        q{UPDATE verdict SET data = replace(data,'"status":"Survived"','"status":"Killed","status":"Survived"') WHERE id = 'ambiguous'}
    );
    $connection->do( 'UPDATE verdict SET data = ? WHERE id = ?', undef, '{',    'broken' );
    $connection->do( 'UPDATE verdict SET data = ? WHERE id = ?', undef, 'null', 'missing' );
    is Test::Mutation::Store::load($path), { intact => $record }, 'only the intact verdict can be reused';
};
subtest 'concurrent writers publish only committed observations' => sub {
    my $path = "$directory/concurrent/measurement.sqlite";
    pipe my $start, my $signal or die "pipe: $!";
    my @children;
    for my $number ( 1 .. 2 ) {
        my $child = fork;
        die "fork: $!" unless defined $child;
        if ( !$child ) {
            close $signal                        or die "close: $!";
            sysread( $start, my $ready, 1 ) == 1 or die "start gate: $!";
            Test::Mutation::Store::save( $path, { $number => $record } );
            POSIX::_exit(0);
        }
        push @children, $child;
    }
    close $start                   or die "close: $!";
    syswrite( $signal, 'xx' ) == 2 or die "release: $!";
    close $signal                  or die "close: $!";
    for my $child (@children) {
        waitpid $child, 0;
        is $?, 0, 'a writer commits successfully';
    }
    my $both = { 1 => $record, 2 => $record };
    is Test::Mutation::Store::load($path), $both, 'both writers survive concurrent database creation';
    my $connection = Test::Mutation::Store::database($path);
    like dies {
        Test::Mutation::Store::transaction(
            $connection,
            sub {
                $connection->do('DELETE FROM verdict');
                die "interrupted publication\n";
            }
        );
    }, qr/interrupted publication/, 'an interrupted transaction returns its original failure';
    is Test::Mutation::Store::load($path), $both, 'a rolled-back write preserves every committed observation';
};

subtest 'measurements in a read-only checkout' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can write to read-only directories' );
    my $read_only = File::Temp::tempdir( CLEANUP => 1 );
    my $config    = Test::Mutation::Settings::of_call( { root => $read_only } );
    my $legacy    = "$read_only/.mutation/cache.json";
    Test::Mutation::Store::save( $legacy, { first => $record } );
    chmod oct('555'), $read_only or die "chmod: $!";
    my $private = Test::Mutation::Store::path($config);
    is Test::Mutation::Store::load($private), { first => $record },
      'input-identified verdicts migrate from a read-only checkout into the private database';
    ok !-e "$read_only/.mutation/measurement.sqlite", 'migration leaves the checkout intact';
    chmod oct('755'), $read_only or die "chmod: $!";
    ok index( $private, "$read_only/" ) != 0, 'a read-only project uses a private database outside the checkout';
    is Test::Mutation::Store::path($config), $private, 'the configuration keeps its private database for the whole run';
};
done_testing;
