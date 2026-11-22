use v5.36;
use utf8;
use Test2::V0;
use Encode ();
use Permutl::Source;

subtest 'UTF-8 bytes decode to characters and encode back' => sub {
    my $bytes  = Encode::encode( 'UTF-8', "my \$挨拶 = 1;\nreturn 2;\n" );
    my $source = Permutl::Source->from_bytes( path => 'lib/A.pm', bytes => $bytes );
    is $source->encoding,                  'UTF-8', 'encoding';
    is length( $source->text ),            22,      'length counts characters';
    is $source->to_bytes( $source->text ), $bytes,  'encoding reproduces the bytes';
};

subtest 'bytes that are not UTF-8 survive as Latin-1' => sub {
    my $bytes  = "my \$caf\xE9 = 1;\n";
    my $source = Permutl::Source->from_bytes( path => 'lib/B.pm', bytes => $bytes );
    is $source->encoding,                  'latin1', 'encoding';
    is $source->to_bytes( $source->text ), $bytes,   'encoding reproduces the bytes';
};

subtest 'positions and offsets are inverse for every character' => sub {
    my $text   = "ab\n\ncdé\nlast";
    my $source = Permutl::Source->new( path => 'x', text => $text, encoding => 'UTF-8' );
    my @failed = grep { $source->offset_of( $source->position_of($_)->@* ) != $_ } 0 .. length($text) - 1;
    is \@failed,                 [], 'offset_of inverts position_of';
    is $source->position_of(0),  [ 1, 1 ], 'first character';
    is $source->position_of(2),  [ 1, 3 ], 'newline belongs to its line';
    is $source->position_of(3),  [ 2, 1 ], 'empty line';
    is $source->position_of(6),  [ 3, 3 ], 'non-ASCII character is one column';
    is $source->position_of(11), [ 4, 4 ], 'last character';
};

subtest 'replace_span changes the span alone' => sub {
    my $source = Permutl::Source->new( path => 'x', text => 'a + b', encoding => 'UTF-8' );
    is $source->replace_span( 2, 3, '-' ), 'a - b', 'operator replaced';
    is $source->replace_span( 2, 3, q{} ), 'a  b',  'span removed';
    is $source->text, 'a + b', 'the source is unchanged';
};

subtest 'arguments are checked' => sub {
    like dies { Permutl::Source->from_bytes( path => 'x' ) }, qr/bytes/, 'missing bytes is refused';
    my $source = Permutl::Source->new( path => 'x', text => 'a', encoding => 'UTF-8' );
    like dies { $source->offset_of( 'one', 1 ) }, qr/Int/, 'a non-integer line is refused';
    like dies { Permutl::Source->new( path => 'x', text => 'a', encoding => 'EBCDIC' ) }, qr/encoding/,
      'an unknown encoding is refused';
};

done_testing;
