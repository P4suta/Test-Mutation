package Test::Mutation::Source;
use v5.36;
use Moo;
use Encode          ();
use Types::Standard qw(ArrayRef Enum InstanceOf Int Maybe Str Tuple);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Try;

our $VERSION = '0.001';

with 'Test::Mutation::Value';

has path         => ( is => 'ro',   isa => Str, required => 1 );
has text         => ( is => 'ro',   isa => Str, required => 1 );
has encoding     => ( is => 'ro',   isa => Enum [ 'UTF-8', 'latin1' ], required => 1 );
has _line_starts => ( is => 'lazy', isa => ArrayRef [Int] );

signature_for read_bytes => ( positional => [Str], returns => Str );

sub read_bytes ($path) {
    open my $handle, '<:raw', $path or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    local $/ = undef;
    my $content = readline $handle;
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return $content // q{};
}

signature_for from_bytes => (
    method  => 1,
    named   => [ path => Str, bytes => Str ],
    returns => InstanceOf ['Test::Mutation::Source'],
);

sub from_bytes ( $class, $arg ) {
    my $bytes = $arg->bytes;
    my $read =
      Test::Mutation::Try::attempt( sub { Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK | Encode::LEAVE_SRC ) } );
    return $class->new( path => $arg->path, text => $read->{value}, encoding => 'UTF-8' ) if exists $read->{value};
    return $class->new( path => $arg->path, text => Encode::decode( 'latin1', $bytes ), encoding => 'latin1' );
}

signature_for to_bytes => ( method => 1, positional => [Str], returns => Str );

sub to_bytes ( $self, $text ) {
    return Encode::encode( $self->encoding, $text );
}

sub _build__line_starts ($self) {
    my $text   = $self->text;
    my @starts = (0);
    push @starts, pos($text) while $text =~ /\n/g;
    return \@starts;
}

signature_for offset_of => ( method => 1, positional => [ Int, Int ], returns => Int );

sub offset_of ( $self, $line, $column ) {
    return $self->_line_starts->[ $line - 1 ] + $column - 1;
}

signature_for offset_within_source => ( method => 1, positional => [ Int, Int ], returns => Maybe [Int] );

sub offset_within_source ( $self, $line, $column ) {
    my $starts = $self->_line_starts;
    return if $line < 1 || $line > @$starts || $column < 1;
    my $offset = $starts->[ $line - 1 ] + $column - 1;
    my $limit  = $line < @$starts ? $starts->[$line] : length( $self->text ) + 1;
    return $offset < $limit ? $offset : undef;
}

signature_for position_of => ( method => 1, positional => [Int], returns => Tuple [ Int, Int ] );

sub position_of ( $self, $offset ) {
    my $starts = $self->_line_starts;
    my $low    = 0;
    my $high   = scalar( $starts->@* ) - 1;
    while ( $low < $high ) {
        my $sum    = $low + $high + 1;
        my $middle = int( $sum / 2 );
        if ( $starts->[$middle] <= $offset ) {
            $low = $middle;
        }
        else {
            $high = $middle - 1;
        }
    }
    return [ $low + 1, $offset - $starts->[$low] + 1 ];
}

signature_for replace_span => ( method => 1, positional => [ Int, Int, Str ], returns => Str );

sub replace_span ( $self, $start, $end, $replacement ) {
    my $text = $self->text;
    substr $text, $start, $end - $start, $replacement;
    return $text;
}

1;

__END__

=head1 NAME

Test::Mutation::Source - the decoded text of one source file

=head1 SYNOPSIS

    my $source = Test::Mutation::Source->from_bytes( path => 'lib/Foo.pm', bytes => $bytes );
    my $offset = $source->offset_of( 12, 5 );
    my $bytes  = $source->to_bytes( $source->replace_span( $start, $end, '-' ) );

=head1 DESCRIPTION

A source holds the characters of a file and the encoding that reproduces its bytes.
Offsets count characters from zero.
Lines and columns count from one.

=head1 ATTRIBUTES

=head2 path

The path of the file inside the project.

=head2 text

The decoded characters of the file.

=head2 encoding

C<UTF-8> or C<latin1>, the encoding that turns the text back into the bytes of the file.

=head1 METHODS

=head2 read_bytes

Reads the original bytes of a file.

=head2 from_bytes

Decodes C<bytes> as UTF-8, and as Latin-1 when the bytes are not valid UTF-8.

=head2 to_bytes

Encodes text with the encoding of the source.

=head2 offset_of

Returns the offset of a line and column.

=head2 offset_within_source

Returns the character offset, or an undefined value for a position outside its line.
The position just past the last character is valid at the end of the file.

=head2 position_of

Returns the line and column of an offset as a two-element array reference.

=head2 replace_span

    my $mutated = $source->replace_span( $start, $end, $replacement );

Returns the text with the characters from offset C<$start> up to offset C<$end> replaced.

=cut
