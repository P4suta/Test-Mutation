package Test::Mutation::Store;
use v5.36;
use DBI                   ();
use Fcntl                 qw(:flock);
use List::Util            ();
use POSIX                 ();
use File::Basename        ();
use File::Spec            ();
use File::Temp            ();
use Hash::Util::FieldHash qw(fieldhash);
use JSON::PP              ();
use Types::Standard       qw(ArrayRef Bool CodeRef Defined Dict HashRef InstanceOf Int Maybe Num Optional Str);
use Type::Params          qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Store::Key;
use Test::Mutation::Status;
use Test::Mutation::Tree;
use Test::Mutation::Try;
use Test::Mutation::Types qw(Observations Reason StatusName);

our $VERSION = '0.001';

my $JSON = JSON::PP->new->canonical;
fieldhash my %private;

my $FORMAT   = 5;
my $LINES    = HashRef [Bool];
my $ORIGINAL = Dict [
    inputs    => Str,
    includes  => ArrayRef [Str],
    duration  => Num,
    files     => HashRef [ Dict [ traced => Bool, hits => $LINES ] ],
    breakable => HashRef [$LINES]
];
my $ORIGINALS = Dict [ build => ArrayRef [Str], tests => HashRef [$ORIGINAL] ];
my $CHANGES   = Dict [ build => ArrayRef [Str], tests => HashRef [ Maybe [$ORIGINAL] ], reset => Optional [Bool] ];
my $RECORD    = (
    Dict [
        inputs       => Str,
        path         => Optional [Str],
        source       => Optional [Str],
        status       => StatusName,
        reason       => Maybe [Reason],
        detail       => Maybe [Str],
        by           => Maybe [Str],
        tests_run    => Int,
        duration     => Num,
        code         => Maybe [Str],
        observations => Optional [Observations],
    ]
)->where(
    sub {
        Test::Mutation::Status::fits( $_->{status}, $_->{reason} ) && defined( $_->{path} ) == defined( $_->{source} );
    }
);

signature_for format_version => ( positional => [], returns => Int );

sub format_version () {
    return $FORMAT;
}

signature_for sample => ( positional => [ ArrayRef [Str], Str ], returns => ArrayRef [Str] );

sub sample ( $ids, $seed ) {
    my $count   = scalar @$ids;
    my $take    = List::Util::min( $count, List::Util::max( 3, POSIX::ceil( $count / 50 ) ) );
    my %rank    = map  { $_ => Test::Mutation::Store::Key::digest( $seed, $_ ) } @$ids;
    my @ordered = sort { $rank{$a} cmp $rank{$b} || $a cmp $b } @$ids;
    return [ @ordered[ 0 .. $take - 1 ] ];
}

signature_for load => ( positional => [Str], returns => HashRef [$RECORD] );

sub load ($path) {
    return _stored( database($path), 'verdict' ) if $path =~ /[.]sqlite\z/;
    return _validated( _read($path)->{mutants}, $RECORD );
}

signature_for originals => ( positional => [Str], returns => $ORIGINALS );

sub originals ($path) {
    if ( $path =~ /[.]sqlite\z/ ) {
        my $db = database($path);
        my ($build) = $db->selectrow_array("SELECT data FROM setting WHERE id = 'build'");
        return { build => defined $build ? $JSON->decode($build) : [], tests => _stored( $db, 'original' ) };
    }
    return _originals( _read($path) );
}

sub _stored ( $db, $table ) {
    my $rows = $db->selectall_arrayref("SELECT id, data FROM $table");
    return { map { $_->[0] => $JSON->decode( $_->[1] ) } @$rows };
}

signature_for path =>
  ( positional => [ InstanceOf ['Test::Mutation::Config'], Bool, { default => 1 } ], returns => Str );

sub path ( $config, $write ) {
    return File::Spec->catfile( $private{$config}, 'measurement.sqlite' ) if exists $private{$config};
    my $stored = File::Spec->catfile( File::Spec->rel2abs( $config->cache_dir, $config->root ), 'measurement.sqlite' );
    return $stored if !$write || !$config->cache || exists $config->specified->{'cache-dir'} || -w $config->root;
    my $directory = File::Temp->newdir;
    my $copy      = File::Spec->catfile( $directory, 'measurement.sqlite' );
    _connect($copy)->sqlite_backup_from_file($stored) if -f $stored;
    $private{$config} = $directory;
    return $copy;
}

signature_for transaction => ( positional => [ InstanceOf ['DBI::db'], CodeRef ], returns => Defined );

sub transaction ( $db, $operation ) {
    $db->begin_work;
    my $committed = Test::Mutation::Try::attempt(
        sub {
            my $value = $operation->();
            $db->commit;
            return $value;
        },
        'interruption'
    );
    return $committed->{value} if exists $committed->{value};
    $db->rollback unless $db->{AutoCommit};
    die $committed->{error};    ## no critic (ErrorHandling::RequireCarping)
}

sub _connect ($path) {
    my $db = DBI->connect(
        "dbi:SQLite:dbname=$path",
        undef, undef,
        {
            RaiseError          => 1,
            PrintError          => 0,
            AutoInactiveDestroy => 1,
            sqlite_unicode      => 1,
            HandleError         => sub ( $message, @ ) {
                Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => $message );
            }
        }
    );
    $db->sqlite_busy_timeout(30_000);
    return $db;
}

signature_for database => ( positional => [Str], returns => InstanceOf ['DBI::db'] );

sub database ($path) {
    my $directory = File::Basename::dirname($path);
    Test::Mutation::Tree::make($directory) unless -d $directory;
    my $db = _connect($path);
    my ($schema) = $db->selectrow_array('PRAGMA user_version');
    return $db if $schema == 1;
    Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "unsupported database schema $schema" )
      if $schema;
    transaction(
        $db,
        sub {
            return 1 if ( $db->selectrow_array('PRAGMA user_version') )[0];
            $db->do('CREATE TABLE verdict (id TEXT PRIMARY KEY, path TEXT, source TEXT, data TEXT NOT NULL)');
            $db->do('CREATE INDEX verdict_path ON verdict(path)');
            $db->do('CREATE TABLE original (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
            $db->do('CREATE TABLE setting (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
            $db->do(
                'CREATE TABLE measurement (run INTEGER PRIMARY KEY, project TEXT, finished REAL, anchor INTEGER, complete INTEGER)'
            );
            $db->do('CREATE INDEX measured_scope ON measurement(project, anchor, run DESC)');
            $db->do(
                'CREATE TABLE observation (run INTEGER, ordinal INTEGER, id TEXT, path TEXT, source TEXT, status TEXT, data TEXT, PRIMARY KEY(run, id))'
            );
            $db->do('CREATE INDEX observed_mutant ON observation(id, source, run)');
            $db->do('CREATE TABLE analysis (identity TEXT PRIMARY KEY, facts TEXT NOT NULL)');
            $db->do(
                'CREATE TABLE candidate (analysis TEXT, ordinal INTEGER, id TEXT, data TEXT NOT NULL, PRIMARY KEY(analysis,id))'
            );
            $db->do('CREATE INDEX catalog_order ON candidate(analysis,ordinal)');
            my $old      = _read("$directory/cache.json");
            my $verdicts = _validated( $old->{mutants}, $RECORD );
            my $matching = { map { $_ => $verdicts->{$_} } grep { defined $verdicts->{$_}{source} } keys %$verdicts };
            _update( $db, $matching, undef, {}, _originals($old) );
            $db->do('PRAGMA user_version = 1');
            return 1;
        }
    );
    return $db;
}

sub _update ( $db, $updates, $inventory, $sources, $changes ) {
    if ($changes) {
        $db->do( 'INSERT OR REPLACE INTO setting VALUES (?,?)', undef, 'build', $JSON->encode( $changes->{build} ) );
        $db->do('DELETE FROM original') if $changes->{reset};
        for my $test ( keys $changes->{tests}->%* ) {
            my $record = $changes->{tests}{$test};
            if ($record) {
                $db->do( 'INSERT OR REPLACE INTO original VALUES (?,?)', undef, $test, $JSON->encode($record) );
            }
            else { $db->do( 'DELETE FROM original WHERE id = ?', undef, $test ) }
        }
    }
    my $write = $db->prepare('INSERT OR REPLACE INTO verdict VALUES (?,?,?,?)');
    for my $id ( keys %$updates ) {
        my $record = $updates->{$id};
        if ( Test::Mutation::Status::of( $record->{status} )->cached ) {
            $write->execute( $id, $record->@{qw(path source)}, $JSON->encode($record) );
        }
        else { $db->do( 'DELETE FROM verdict WHERE id = ?', undef, $id ) }
    }
    if ( defined $inventory ) {
        $db->do('CREATE TEMP TABLE eligible (id TEXT PRIMARY KEY)');
        my $keep = $db->prepare('INSERT OR IGNORE INTO eligible VALUES (?)');
        $keep->execute($_) for @$inventory;
        $db->do('DELETE FROM verdict WHERE id NOT IN (SELECT id FROM eligible)');
        $db->do('DROP TABLE eligible');
    }
    for my $file ( keys %$sources ) {
        $db->do( 'DELETE FROM verdict WHERE path = ? AND source <> ?', undef, $file, $sources->{$file} );
    }
    return ( $db->selectrow_array('SELECT count(*) FROM verdict') )[0];
}

sub _originals ($data) {
    my $build = $data->{build};
    return {
        build => ( ArrayRef [Str] )->check($build) ? $build : [],
        tests => _validated( $data->{tests}, $ORIGINAL ),
    };
}

sub _validated ( $records, $type ) {
    return {} if ref $records ne 'HASH';
    return { map { $_ => $records->{$_} } grep { $type->check( $records->{$_} ) } keys %$records };
}

sub _read ($path) {
    open my $handle, '<:raw', $path or return {};
    my $text = do { local $/ = undef; readline $handle };
    close $handle or return {};
    my $read   = Test::Mutation::Try::attempt( sub { return [ JSON::PP->new->utf8->decode($text) ] } );
    my ($data) = ( $read->{value} || [] )->@*;
    return ref $data eq 'HASH' && ( $data->{version} || 0 ) eq $FORMAT ? $data : {};
}

signature_for save => (
    positional => [
        Str,
        HashRef [$RECORD],
        Maybe [ ArrayRef [Str] ],
        { default => undef },
        HashRef [Str],
        { default => sub { {} } },
        Maybe [$CHANGES],
        { default => undef }
    ],
    returns => Int
);

sub save ( $path, $updates, $inventory, $sources, $originals ) {
    if ( $path =~ /[.]sqlite\z/ ) {
        my $db = database($path);
        return transaction( $db, sub { _update( $db, $updates, $inventory, $sources, $originals ) } );
    }
    Test::Mutation::Tree::make( File::Basename::dirname($path) );
    open my $lock, '>>', "$path.lock"
      or Test::Mutation::Error::raise( 'file-unwritable', path => "$path.lock", reason => "$!" );
    flock $lock, LOCK_EX or Test::Mutation::Error::raise( 'file-unwritable', path => "$path.lock", reason => "$!" );
    my $count = _merge_records( $path, $updates, $inventory, $sources, $originals );
    close $lock or Test::Mutation::Error::raise( 'file-unclosable', path => "$path.lock", reason => "$!" );
    return $count;
}

sub _merge_records ( $path, $updates, $inventory, $sources, $changes ) {
    my $data      = _read($path);
    my $originals = _originals($data);
    if ($changes) {
        $originals->{build} = $changes->{build};
        $originals->{tests} = {} if $changes->{reset};
        for my $test ( keys $changes->{tests}->%* ) {
            my $record = $changes->{tests}{$test};
            if ($record) { $originals->{tests}{$test} = $record }
            else         { delete $originals->{tests}{$test} }
        }
    }
    my %records  = ( _validated( $data->{mutants}, $RECORD )->%*, %$updates );
    my %eligible = map { $_ => 1 } @{ $inventory || [ keys %records ] };
    my %kept     = map { $_ => $records{$_} } grep {
        my $record = $records{$_};
        $eligible{$_}
          && Test::Mutation::Status::of( $record->{status} )->cached
          && ( !exists $record->{path}
            || !exists $sources->{ $record->{path} }
            || $record->{source} eq $sources->{ $record->{path} } )
    } keys %records;
    my $temporary = "$path.$$";
    open my $handle, '>:raw', $temporary
      or Test::Mutation::Error::raise( 'file-unwritable', path => $temporary, reason => "$!" );
    print {$handle} JSON::PP->new->utf8->canonical->encode( { version => $FORMAT, mutants => \%kept, $originals->%* } )
      or Test::Mutation::Error::raise( 'file-unwritable', path => $temporary, reason => "$!" );
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $temporary, reason => "$!" );
    rename $temporary, $path or Test::Mutation::Error::raise( 'file-unrenamable', path => $temporary, reason => "$!" );
    return scalar keys %kept;
}

1;

__END__

=head1 NAME

Test::Mutation::Store - results of earlier runs, keyed by what each result depends on

=head1 SYNOPSIS

    my $records = Test::Mutation::Store::load('.mutation/cache.json');
    my $key     = Test::Mutation::Store::Key::digest( $version, $source_text, @test_digests );
    my $reuse   = $records->{$id} && $records->{$id}{inputs} eq $key;

=head1 DESCRIPTION

A record holds the result of one mutant and, under C<inputs>, the key of its inputs.
No field is named after a key, because a secret scanner reads such a name next to a digest as a credential.
A later run reuses the record when the key of the same mutant is unchanged.

=head1 FUNCTIONS

=head2 database

Opens the indexed store and imports reusable records from the previous cache on creation.

=head2 path

Returns the database path for a configured project.
Pass a false second argument for a read on a read-only checkout.
A write uses a temporary snapshot that lasts for the life of the configuration.

=head2 transaction

Runs a database update and commits its return value with the completed work.

=head2 format_version

Returns the schema version included in the measurement fingerprint.

=head2 sample

Selects one reusable verdict for every fifty, rounded up, with at least three when available.
The seed changes the selection between runs.

=head2 load

Returns the records of a cache file by mutant identifier.
A missing file, a file of another format, and a malformed record count as absent.
A record holds a status of L<Test::Mutation::Status>, the reason that its status calls for, and a sentence about the case in C<detail>.

=head2 originals

Returns the build command and the passing observations indexed by test path.
Each observation records the input digest, external include directories, covered targets, breakable lines, and duration.

=head2 save

Writes the records whose status the catalog marks as C<cached>, and returns their number.
Passing original tests and verdicts share one locked update.
An undefined test observation removes an earlier passing result.
A timeout depends on the load of the machine, so the next run measures it again.

=cut
