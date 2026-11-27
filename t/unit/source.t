use v5.36;
use utf8;
use Test2::V0;
use Encode ();
use lib 't/lib';
use Bounded;
use Test::Mutation::Source;

subtest 'UTF-8 bytes decode to characters and encode back' => sub {
    my $bytes  = Encode::encode( 'UTF-8', "my \$挨拶 = 1;\nreturn 2;\n" );
    my $source = Test::Mutation::Source->from_bytes( path => 'lib/A.pm', bytes => $bytes );
    is $source->encoding,                  'UTF-8', 'encoding';
    is length( $source->text ),            22,      'length counts characters';
    is $source->to_bytes( $source->text ), $bytes,  'encoding reproduces the bytes';
};

subtest 'bytes that are not UTF-8 survive as Latin-1' => sub {
    my $bytes  = "my \$caf\xE9 = 1;\n";
    my $source = Test::Mutation::Source->from_bytes( path => 'lib/B.pm', bytes => $bytes );
    is $source->encoding,                  'latin1', 'encoding';
    is $source->to_bytes( $source->text ), $bytes,   'encoding reproduces the bytes';
};

subtest 'positions and offsets are inverse for every character' => sub {
    my $text   = "ab\n\ncdé\nlast";
    my $source = Test::Mutation::Source->new( path => 'x', text => $text, encoding => 'UTF-8' );
    my ( $ended, @failed ) = Bounded::ended(
        2,
        sub {
            return grep { $source->offset_of( $source->position_of($_)->@* ) != $_ } 0 .. length($text) - 1;
        }
    );
    ok $ended, 'the position search terminates for every character';
    return unless $ended;
    is \@failed,                 [], 'offset_of inverts position_of';
    is $source->position_of(0),  [ 1, 1 ], 'first character';
    is $source->position_of(2),  [ 1, 3 ], 'newline belongs to its line';
    is $source->position_of(3),  [ 2, 1 ], 'empty line';
    is $source->position_of(6),  [ 3, 3 ], 'non-ASCII character is one column';
    is $source->position_of(11), [ 4, 4 ], 'last character';
};

subtest 'a trailing newline starts an empty line at the end of the source' => sub {
    my $source = Test::Mutation::Source->new( path => 'x', text => "a\nb\n", encoding => 'UTF-8' );
    my ( $ended, @positions ) = Bounded::ended(
        2,
        sub {
            return map { $source->position_of($_) } 0 .. 4;
        }
    );
    ok $ended, 'the search terminates for each character and the end of the source';
    is \@positions, [ [ 1, 1 ], [ 1, 2 ], [ 2, 1 ], [ 2, 2 ], [ 3, 1 ] ], 'the last newline starts line three'
      if $ended;
};

subtest 'a position must belong to its stated line or the end of the file' => sub {
    for my $text ( q{}, "日\r\n\n", "a\né" ) {
        my $source = Test::Mutation::Source->new( path => 'x', text => $text, encoding => 'UTF-8' );
        for my $offset ( 0 .. length $text ) {
            my $position = $source->position_of($offset);
            is $source->offset_within_source(@$position), $offset, "character $offset in [$text]";
        }
        is $source->offset_within_source( 0, 1 ),  undef, 'line zero has no offset';
        is $source->offset_within_source( 1, 0 ),  undef, 'column zero has no offset';
        is $source->offset_within_source( 4, 1 ),  undef, 'a missing line has no offset';
        is $source->offset_within_source( 1, 10 ), undef, 'a column beyond its line has no offset';
    }
    my $source = Test::Mutation::Source->new( path => 'x', text => "a\nb", encoding => 'UTF-8' );
    is $source->offset_within_source( 1, 3 ), undef, 'the column after a newline belongs to the next line';
    is $source->offset_within_source( 2, 3 ), undef, 'the column after the end-of-file position has no offset';
};

subtest 'replace_span changes the span alone' => sub {
    my $source = Test::Mutation::Source->new( path => 'x', text => 'a + b', encoding => 'UTF-8' );
    is $source->replace_span( 2, 3, '-' ), 'a - b', 'operator replaced';
    is $source->replace_span( 2, 3, q{} ), 'a  b',  'span removed';
    is $source->text, 'a + b', 'the source is unchanged';
};

subtest 'arguments are checked' => sub {
    like dies { Test::Mutation::Source->from_bytes( path => 'x' ) }, qr/bytes/, 'missing bytes is refused';
    my $source = Test::Mutation::Source->new( path => 'x', text => 'a', encoding => 'UTF-8' );
    like dies { $source->position_of(0.5) },      qr/Int/, 'a fractional character offset is refused';
    like dies { $source->offset_of( 'one', 1 ) }, qr/Int/, 'a non-integer line is refused';
    like dies { Test::Mutation::Source->new( path => 'x', text => 'a', encoding => 'EBCDIC' ) }, qr/encoding/,
      'an unknown encoding is refused';
};

done_testing;
