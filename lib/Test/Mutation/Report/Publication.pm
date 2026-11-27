package Test::Mutation::Report::Publication;
use v5.36;
use Cwd             ();
use Digest::SHA     ();
use Fcntl           qw(O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK O_RDONLY O_RDWR SEEK_SET S_ISREG);
use File::Spec      ();
use Types::Standard qw(ArrayRef Dict HashRef Maybe Optional Str StrMatch Undef);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;

our $VERSION = '0.001';

my $NAME      = '.test-mutation-outputs';
my @FILES     = qw(mutation.json mutation.html);
my $HEX       = qr/[0-9a-f]{64}/;
my $DIGEST    = StrMatch [qr/\A$HEX\z/];
my $RECORD    = Dict [ map { ( $_ => Optional [$DIGEST] ) } @FILES ];
my $MAX_BYTES = 256;

sub _seal ( $relative, @digests ) {
    my $path = length $relative ? $relative : q{.};
    utf8::encode($path) if utf8::is_utf8($path);
    return Digest::SHA::sha256_hex( join "\0", $path, @digests );
}

signature_for names => ( positional => [], returns => ArrayRef [Str] );

sub names () {
    return [ $NAME, @FILES ];
}

signature_for outputs => ( positional => [ Str, Str ], returns => HashRef [ Maybe [Str] ] );

sub outputs ( $directory, $relative ) {
    my $path = "$directory/$NAME";
    sysopen my $input, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK or return {};
    my $values = _outputs( $input, $relative );
    close $input or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return $values;
}

sub _outputs ( $input, $relative ) {
    my ( $mode, $links ) = ( stat $input )[ 2, 3 ];
    return {} unless S_ISREG($mode);
    return {} if $links != 1 || $mode & oct '111';
    my $size = sysread( $input, my $text, $MAX_BYTES );
    return {} if !defined $size || $size >= $MAX_BYTES;
    my ( $seal, @values ) = split /\n/, $text, -1;
    return {} unless @values == 3 && pop(@values) eq q{} && $seal eq _seal( $relative, @values );
    return {} if grep { $_ ne q{-} && $_ !~ /\A$HEX\z/ } @values;
    return { $NAME => undef, map { $values[$_] ne q{-} ? ( $FILES[$_] => $values[$_] ) : () } 0 .. $#FILES };
}

signature_for record => ( positional => [ Str, Str, $RECORD ], returns => Undef );

sub record ( $root, $directory, $digests ) {
    my $relative = File::Spec->abs2rel( Cwd::abs_path($directory), Cwd::abs_path($root) );
    return if $relative eq q{..} || index( $relative, '../' ) == 0;
    my $path = "$directory/$NAME";
    my $old  = {};
    my $file;
    if ( !sysopen $file, $path, O_RDWR | O_CREAT | O_EXCL, oct '600' ) {
        Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" ) unless $!{EEXIST};
        sysopen $file, $path, O_RDWR | O_NOFOLLOW | O_NONBLOCK or return;
        $old = _outputs( $file, $relative );
        return unless exists $old->{$NAME};
        sysseek $file, 0, SEEK_SET or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
    }
    my %values = ( %$old, %$digests );
    my @slots  = map { $values{$_} || q{-} } @FILES;
    my $text   = join "\n", _seal( $relative, @slots ), @slots, q{};
    my $size   = syswrite $file, $text;
    Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" )
      if !defined $size || $size != length $text;
    close $file or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Report::Publication - identify unchanged reports at their published paths

=head1 FUNCTIONS

=head2 names

Returns the names a publisher can change while holding its directory lock.

=head2 record

Records the SHA-256 digests of published UTF-8 bytes in the report directory under the publisher's directory lock.
The project-relative directory and both digests identify the record.
An external report directory or an unrelated file at the metadata path receives no record.

=head2 outputs

Returns the expected digest of each published report in the supplied project-relative directory.
A recognized metadata file has an undefined digest in the returned hash.

=cut
