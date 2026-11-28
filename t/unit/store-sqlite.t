use v5.36;
use Test2::V0;
use DBI;
use File::Temp ();
use POSIX      ();
use lib 't/lib';
use Capability;
use Test::Mutation::Settings;
use Test::Mutation::Source;
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

subtest 'reusable records can be read before an interrupted migration resumes' => sub {
    my $saved = { build => [ 'perl', 'Makefile.PL' ], tests => {} };
    my $old   = "$directory/partial/cache.json";
    Test::Mutation::Store::save( $old, { earlier => $record }, undef, {}, $saved );
    for my $case (
        [ verdicts => \&Test::Mutation::Store::load,      { earlier => $record } ],
        [ baseline => \&Test::Mutation::Store::originals, $saved ]
      )
    {
        my ( $name, $read, $expected ) = @$case;
        my $empty = "$directory/partial/$name.sqlite";
        open my $file, '>:raw', $empty or die "create $empty: $!";
        close $file or die "close $empty: $!";
        is $read->($empty), $expected, "the $name lookup can use the legacy cache";
        is -s $empty,       0,         "reading $name leaves the incomplete SQLite file untouched";
    }
    my %unidentified = %$record;
    delete @unidentified{qw(path source)};
    Test::Mutation::Store::save( $old, { other => $record, unidentified => \%unidentified } );
    is Test::Mutation::Store::load( "$directory/partial/verdicts.sqlite", [qw(missing unidentified earlier)] ),
      { earlier => $record }, 'selection from the JSON fallback requires both a requested identifier and known source';
};

my $db = DBI->connect( "dbi:SQLite:dbname=$database", undef, undef, { RaiseError => 1, PrintError => 0 } );
is $db->selectcol_arrayref('SELECT id FROM verdict ORDER BY id'), [qw(first second)],
  'the driver persists a separately addressable row for each verdict';
subtest 'cache paths preserve filename punctuation' => sub {
    my $literal = "$directory/cache;name=100%24?#/measurement.sqlite";
    Test::Mutation::Store::save( $literal, { punctuated => $record } );
    ok -f $literal, 'the database occupies the complete requested path';
    is Test::Mutation::Store::load($literal), { punctuated => $record }, 'the requested database contains the verdict';
};

subtest 'a cache file in another format keeps its bytes and falls back to legacy records' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    my $path = "$root/measurement.sqlite";
    my $data = "other application\0data\n";
    open my $file, '>:raw', $path or die "create $path: $!";
    print {$file} $data;
    close $file or die "close $path: $!";
    is lives { is Test::Mutation::Store::load($path), {}, 'a missing legacy cache yields no verdict' }, T(),
      'reading an unrecognized file counts as a cache miss';
    my $baseline = { build => ['perl'], tests => {} };
    Test::Mutation::Store::save( "$root/cache.json", { previous => $record }, undef, {}, $baseline );
    is lives {
        is Test::Mutation::Store::load($path), { previous => $record }, 'verified legacy verdicts are available';
        is Test::Mutation::Store::originals($path), $baseline, 'the legacy build is available';
    }, T(), 'legacy fallback works when the SQLite path contains other bytes';
    like dies { Test::Mutation::Store::save( $path, { later => $record } ) }, qr/\Q$path\E.*--no-cache.*--cache-dir/,
      'a writer names ways to finish the measurement while preserving the file';
    is Test::Mutation::Source::read_bytes($path), $data, 'both operations preserve the original bytes';
};

subtest 'an unsupported SQLite schema remains an actionable error' => sub {
    my $path       = "$directory/future.sqlite";
    my $connection = DBI->connect( "dbi:SQLite:dbname=$path", undef, undef, { RaiseError => 1, PrintError => 0 } );
    $connection->do('PRAGMA user_version = 314');
    like dies { Test::Mutation::Store::load($path) }, qr/unsupported database schema 314/,
      'the reader reports the version of an existing SQLite database';
    like dies { Test::Mutation::Store::save( $path, { later => $record } ) }, qr/unsupported database schema 314/,
      'the writer preserves an unsupported schema';
    is $connection->selectrow_array('PRAGMA user_version'), 314, 'the original schema version survives';
};

subtest 'an unreadable SQLite database reports the access failure' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can read protected files' );
    my $path = "$directory/protected/measurement.sqlite";
    Test::Mutation::Store::save( $path, { earlier => $record } );
    chmod oct('000'), $path or die "protect $path: $!";
    my $error = dies { Test::Mutation::Store::load($path) };
    chmod oct('600'), $path or die "restore $path: $!";
    like $error, qr/cannot read \Q$path\E/, 'a permission error remains visible at the database path';
    is Test::Mutation::Store::load($path), { earlier => $record }, 'restoring access recovers the original verdict';
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

subtest 'a damaged build setting preserves independently recorded baseline observations' => sub {
    my $path  = "$directory/build/measurement.sqlite";
    my $build = [ 'perl', 'Makefile.PL' ];
    my $tests = { 't/sum.t' => { inputs => 'measured', includes => [], duration => 1, files => {}, breakable => {} } };
    Test::Mutation::Store::save( $path, {}, undef, {}, { build => $build, tests => $tests } );
    is Test::Mutation::Store::originals($path), { build => $build, tests => $tests }, 'valid build arguments survive';
    my $connection = Test::Mutation::Store::database($path);
    for my $case (
        [ 'broken JSON'   => '{' ],
        [ 'object'        => '{}' ],
        [ 'nested object' => '["perl",{}]' ],
        [ 'null argument' => '["perl",null]' ]
      )
    {
        my ( $fault, $value ) = @$case;
        $connection->do( q{UPDATE setting SET data = ? WHERE id = 'build'}, undef, $value );
        my $saved;
        my $error = dies { $saved = Test::Mutation::Store::originals($path) };
        is [ $error, $saved ], [ undef, { build => [], tests => $tests } ], "the baseline survives $fault";
    }
};

subtest 'invalidating one source takes bounded work as unrelated verdicts grow' => sub {
    my $path    = "$directory/pruning/measurement.sqlite";
    my $current = { %$record, source => 'current' };
    my $open    = \&Test::Mutation::Store::database;
    my $prune   = sub ($remaining) {
        Test::Mutation::Store::save( $path, { changed => $record, current => $current } );
        my $hundreds = 0;
        {
            no warnings 'redefine';
            local *Test::Mutation::Store::database = sub ($file) {
                my $connection = $open->($file);
                $connection->sqlite_progress_handler( 100, sub { $hundreds++; return 0 } );
                return $connection;
            };
            is Test::Mutation::Store::save( $path, {}, undef, { $record->{path} => $current->{source} } ), $remaining,
              'only the obsolete verdict is removed';
        }
        is Test::Mutation::Store::load( $path, [qw(changed current)] ), { current => $current },
          'the matching source revision remains reusable';
        return $hundreds;
    };
    my $small = $prune->(1);
    Test::Mutation::Store::save( $path, { map { $_ => { %$record, path => "lib/Other$_.pm" } } 1 .. 1_000 } );
    cmp_ok $prune->(1_001), '<=', $small + 1,
      'one thousand unrelated paths cost at most one extra block of one hundred SQLite operations';
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
    is $connection->selectcol_arrayref('SELECT id FROM verdict ORDER BY id'), [qw(1 2)],
      'the writer sees the previously committed observations after its transaction fails';
    is Test::Mutation::Store::load($path), $both, 'a rolled-back write preserves every committed observation';
};

subtest 'a nonblocking checkpoint retries only a competing writer' => sub {
    my $path  = "$directory/checkpoints/measurement.sqlite";
    my $write = Test::Mutation::Store::checkpoints($path);
    my $peer  = Test::Mutation::Store::database($path);
    $peer->do('BEGIN IMMEDIATE');
    is $write->( 'example', $record, 0 ), 0, 'a competing write lock leaves the observation pending';
    is $peer->selectrow_array('SELECT count(*) FROM verdict'), 0, 'no partial observation is visible';
    $peer->do('COMMIT');
    is $write->( 'example', $record, 0 ), 1, 'the pending observation commits when the lock clears';
    is Test::Mutation::Store::load($path), { example => $record }, 'another connection sees the commit';
    $peer->do(q{CREATE TRIGGER reject BEFORE INSERT ON verdict BEGIN SELECT RAISE(ABORT,'rejected record'); END});
    like dies { $write->( 'refused', $record, 0 ) }, qr/rejected record/,
      'a rejected write passes its failure to the caller';
};

subtest 'legacy checkpoints defer file locking until the caller can wait' => sub {
    my $path  = "$directory/legacy-checkpoint/cache.json";
    my $write = Test::Mutation::Store::checkpoints($path);
    is $write->( 'first', $record, 0 ), 0, 'the nonblocking attempt leaves the observation pending';
    ok !-e "$path.lock", 'a deferred checkpoint creates no lock file';
    is $write->( 'first', $record, 1 ), 1, 'a blocking retry acknowledges the saved observation';
    is $write->( 'second', $record ), undef, 'a caller without a wait argument retains its return contract';
    is Test::Mutation::Store::load($path), { first => $record, second => $record }, 'both observations are durable';
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

subtest 'a read-only checkout can recover an unfinished legacy migration' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can write to read-only directories' );
    my $root   = File::Temp::tempdir( CLEANUP => 1 );
    my $config = Test::Mutation::Settings::of_call( { root => $root } );
    Test::Mutation::Store::save( "$root/.mutation/cache.json", { previous => $record } );
    my $sqlite = Test::Mutation::Store::path( $config, 0 );
    open my $empty, '>:raw', $sqlite or die "create $sqlite: $!";
    close $empty or die "close $sqlite: $!";
    chmod oct('555'), $root or die "protect $root: $!";
    my $copy = Test::Mutation::Store::path($config);
    is Test::Mutation::Store::load($copy), { previous => $record },
      'the private measurement retains the legacy verdict';
    is -s $sqlite, 0, 'the unfinished database in the checkout still contains no schema';
    chmod oct('755'), $root or die "restore $root: $!";
};
done_testing;
