package Permutl::Cache;
use v5.36;
use Digest::SHA     ();
use Encode          ();
use File::Basename  ();
use File::Path      ();
use JSON::PP        ();
use Types::Standard qw(Dict HashRef Int Maybe Num Slurpy Str ArrayRef);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my $FORMAT = 2;
my %KEPT   = map { $_ => 1 } qw(Killed Survived CompileError Ignored);
my $RECORD = Dict [
    inputs    => Str,
    status    => Str,
    reason    => Maybe [Str],
    by        => Maybe [Str],
    tests_run => Int,
    duration  => Num,
    code      => Maybe [Str],
];

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
    my $data = eval { JSON::PP->new->utf8->decode($text) };
    return {} if ref $data ne 'HASH' || ( $data->{version} || 0 ) != $FORMAT || ref $data->{mutants} ne 'HASH';
    my %records =
      map { $_ => $data->{mutants}{$_} } grep { $RECORD->check( $data->{mutants}{$_} ) } keys $data->{mutants}->%*;
    return \%records;
}

signature_for save => ( positional => [ Str, HashRef [$RECORD] ], returns => Int );

sub save ( $path, $records ) {
    my %kept = map { $_ => $records->{$_} } grep { $KEPT{ $records->{$_}{status} } } keys $records->%*;
    File::Path::make_path( File::Basename::dirname($path) );
    my $temporary = "$path.$$";
    open my $handle, '>:raw', $temporary or die "write $temporary: $!\n";
    print {$handle} JSON::PP->new->utf8->canonical->encode( { version => $FORMAT, mutants => \%kept } )
      or die "write $temporary: $!\n";
    close $handle or die "close $temporary: $!\n";
    rename $temporary, $path or die "rename $temporary: $!\n";
    return scalar keys %kept;
}

1;

__END__

=head1 NAME

Permutl::Cache - results of earlier runs, keyed by what each result depends on

=head1 SYNOPSIS

    my $records = Permutl::Cache::load('.permutl/cache.json');
    my $key     = Permutl::Cache::key( $version, $source_text, @test_digests );
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

=head2 save

Writes the records with the statuses C<Killed>, C<Survived>, C<CompileError>, and C<Ignored>, and returns their number.
A timeout depends on the load of the machine, so the next run measures it again.

=cut
