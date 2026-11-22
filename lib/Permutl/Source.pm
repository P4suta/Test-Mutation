package Permutl::Source;
use v5.36;
use Moo;
use Encode          ();
use Types::Standard qw(ArrayRef Enum InstanceOf Int Str Tuple);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

has path         => ( is => 'ro',   isa => Str, required => 1 );
has text         => ( is => 'ro',   isa => Str, required => 1 );
has encoding     => ( is => 'ro',   isa => Enum [ 'UTF-8', 'latin1' ], required => 1 );
has _line_starts => ( is => 'lazy', isa => ArrayRef [Int] );

signature_for from_bytes => (
    method  => 1,
    named   => [ path => Str, bytes => Str ],
    returns => InstanceOf ['Permutl::Source'],
);

sub from_bytes ( $class, $arg ) {
    my $bytes = $arg->bytes;
    my $text  = eval { Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK | Encode::LEAVE_SRC ) };
    return $class->new( path => $arg->path, text => $text, encoding => 'UTF-8' ) if defined $text;
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

Permutl::Source - the decoded text of one source file

=head1 SYNOPSIS

    my $source = Permutl::Source->from_bytes( path => 'lib/Foo.pm', bytes => $bytes );
    my $offset = $source->offset_of( 12, 5 );
    my $bytes  = $source->to_bytes( $source->splice( $start, $end, '-' ) );

=head1 DESCRIPTION

A source holds the characters of a file and the encoding that reproduces its bytes.
Offsets count characters from zero.
Lines and columns count from one.

=head1 METHODS

=head2 from_bytes

Decodes C<bytes> as UTF-8, and as Latin-1 when the bytes are not valid UTF-8.

=head2 to_bytes

Encodes text with the encoding of the source.

=head2 offset_of

Returns the offset of a line and column.

=head2 position_of

Returns the line and column of an offset as a two-element array reference.

=head2 splice

Returns the text with the span from C<$start> to C<$end> replaced.

=cut
