package Test::Mutation::Cache;
use v5.36;
use Digest::SHA     ();
use Encode          ();
use File::Basename  ();
use JSON::PP        ();
use Types::Standard qw(Dict HashRef Int Maybe Num Slurpy Str ArrayRef);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Status;
use Test::Mutation::Tree;
use Test::Mutation::Try;
use Test::Mutation::Types qw(Reason StatusName);

our $VERSION = '0.001';

# The third format holds the reason of a status from the catalog and the sentence about the case apart.
my $FORMAT = 3;
my $RECORD = (
    Dict [
        inputs    => Str,
        status    => StatusName,
        reason    => Maybe [Reason],
        detail    => Maybe [Str],
        by        => Maybe [Str],
        tests_run => Int,
        duration  => Num,
        code      => Maybe [Str],
    ]
)->where( sub { Test::Mutation::Status::fits( $_->{status}, $_->{reason} ) } );

signature_for key => ( positional => [ Slurpy [ ArrayRef [Str] ] ], returns => Str );

sub key ($parts) {
    my $digest = Digest::SHA->new(256);
    for my $part ( $parts->@* ) {
        my $bytes = Encode::encode( 'UTF-8', $part );
        $digest->add( length($bytes) . q{:} . $bytes );
    }
    return $digest->hexdigest;
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

signature_for save => ( positional => [ Str, HashRef [$RECORD] ], returns => Int );

sub save ( $path, $records ) {
    my %kept = map { $_ => $records->{$_} }
      grep { Test::Mutation::Status::of( $records->{$_}{status} )->cached } keys $records->%*;
    Test::Mutation::Tree::make( File::Basename::dirname($path) );
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

Test::Mutation::Cache - results of earlier runs, keyed by what each result depends on

=head1 SYNOPSIS

    my $records = Test::Mutation::Cache::load('.mutation/cache.json');
    my $key     = Test::Mutation::Cache::key( $version, $source_text, @test_digests );
    my $reuse   = $records->{$id} && $records->{$id}{inputs} eq $key;

=head1 DESCRIPTION

A record holds the result of one mutant and, under C<inputs>, the key of its inputs.
No field is named after a key, because a secret scanner reads such a name next to a digest as a credential.
A later run reuses the record when the key of the same mutant is unchanged.

=head1 FUNCTIONS

=head2 key

Returns a digest of a list of strings.
Each part enters the digest with its length, so two lists with different boundaries give different keys.

=head2 load

Returns the records of a cache file by mutant identifier.
A missing file, a file of another format, and a malformed record count as absent.
A record holds a status of L<Test::Mutation::Status>, the reason that its status calls for, and a sentence about the case in C<detail>.

=head2 save

Writes the records whose status the catalog marks as C<cached>, and returns their number.
A timeout depends on the load of the machine, so the next run measures it again.

=cut
