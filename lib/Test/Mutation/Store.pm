package Test::Mutation::Store;
use v5.36;
use Fcntl           qw(:flock);
use List::Util      ();
use POSIX           ();
use File::Basename  ();
use JSON::PP        ();
use Types::Standard qw(ArrayRef Dict HashRef Int Maybe Num Optional Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Store::Key;
use Test::Mutation::Status;
use Test::Mutation::Tree;
use Test::Mutation::Try;
use Test::Mutation::Types qw(Reason StatusName);

our $VERSION = '0.001';

my $FORMAT = 4;
my $RECORD = (
    Dict [
        inputs    => Str,
        path      => Optional [Str],
        source    => Optional [Str],
        status    => StatusName,
        reason    => Maybe [Reason],
        detail    => Maybe [Str],
        by        => Maybe [Str],
        tests_run => Int,
        duration  => Num,
        code      => Maybe [Str],
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
    open my $handle, '<:raw', $path or return {};
    my $text = do { local $/ = undef; readline $handle };
    close $handle or return {};
    my $read   = Test::Mutation::Try::attempt( sub { return [ JSON::PP->new->utf8->decode($text) ] } );
    my ($data) = ( $read->{value} || [] )->@*;
    return {} if ref $data ne 'HASH' || ( $data->{version} || 0 ) != $FORMAT || ref $data->{mutants} ne 'HASH';
    my %records =
      map { $_ => $data->{mutants}{$_} } grep { $RECORD->check( $data->{mutants}{$_} ) } keys $data->{mutants}->%*;
    return \%records;
}

signature_for save => (
    positional => [
        Str,
        HashRef [$RECORD],
        Maybe [ ArrayRef [Str] ],
        { default => undef },
        HashRef [Str],
        { default => sub { {} } }
    ],
    returns => Int
);

sub save ( $path, $updates, $inventory, $sources ) {
    Test::Mutation::Tree::make( File::Basename::dirname($path) );
    open my $lock, '>>', "$path.lock"
      or Test::Mutation::Error::raise( 'file-unwritable', path => "$path.lock", reason => "$!" );
    flock $lock, LOCK_EX or Test::Mutation::Error::raise( 'file-unwritable', path => "$path.lock", reason => "$!" );
    my $count = _merge_records( $path, $updates, $inventory, $sources );
    close $lock or Test::Mutation::Error::raise( 'file-unclosable', path => "$path.lock", reason => "$!" );
    return $count;
}

sub _merge_records ( $path, $updates, $inventory, $sources ) {
    my %records  = ( load($path)->%*, %$updates );
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
    print {$handle} JSON::PP->new->utf8->canonical->encode( { version => $FORMAT, mutants => \%kept } )
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

=head2 format_version

Returns the schema version included in the measurement fingerprint.

=head2 sample

Selects one reusable verdict for every fifty, rounded up, with at least three when available.
The seed changes the selection between runs.

=head2 load

Returns the records of a cache file by mutant identifier.
A missing file, a file of another format, and a malformed record count as absent.
A record holds a status of L<Test::Mutation::Status>, the reason that its status calls for, and a sentence about the case in C<detail>.

=head2 save

Writes the records whose status the catalog marks as C<cached>, and returns their number.
A timeout depends on the load of the machine, so the next run measures it again.

=cut
