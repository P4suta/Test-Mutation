use v5.36;
use Test2::V0;
use Permutl::Mutant;
use Permutl::Report::Patch;

my $text = join q{}, map { "line $_\n" } 1 .. 10;

sub patch ( $source, $original, $replacement ) {
    my $start  = index $source, $original;
    my $mutant = Permutl::Mutant->new(
        id          => 'abcdefabcdef',
        path        => 'lib/X.pm',
        mutator     => 'string-literal',
        start       => $start,
        end         => $start + length $original,
        original    => $original,
        replacement => $replacement,
        description => 'changed',
        from        => [ 1, 1 ],
        to          => [ 1, 2 ],
        scope       => [ 1, 1 ],
    );
    return Permutl::Report::Patch::render( mutant => $mutant, text => $source );
}

sub hunk ( $header, @lines ) {
    return join q{}, map { "$_\n" } '--- lib/X.pm', '+++ lib/X.pm', $header, @lines;
}

my @cases = (
    [ 'line 5',  'LINE 5',  '@@ -3,5 +3,5 @@', ' line 3', ' line 4', '-line 5',  '+LINE 5', ' line 6', ' line 7' ],
    [ 'line 1',  'LINE 1',  '@@ -1,3 +1,3 @@', '-line 1', '+LINE 1', ' line 2',  ' line 3' ],
    [ 'line 2',  'LINE 2',  '@@ -1,4 +1,4 @@', ' line 1', '-line 2', '+LINE 2',  ' line 3', ' line 4' ],
    [ 'line 3',  'LINE 3',  '@@ -1,5 +1,5 @@', ' line 1', ' line 2', '-line 3',  '+LINE 3', ' line 4', ' line 5' ],
    [ 'line 10', 'LINE 10', '@@ -8,3 +8,3 @@', ' line 8', ' line 9', '-line 10', '+LINE 10' ],
    [ 'line 9',  'LINE 9',  '@@ -7,4 +7,4 @@', ' line 7', ' line 8', '-line 9',  '+LINE 9', ' line 10' ],
    [ 'line 8',  'LINE 8',  '@@ -6,5 +6,5 @@', ' line 6', ' line 7', '-line 8',  '+LINE 8', ' line 9', ' line 10' ],
    [
        "line 5\nline 6",
        "\n", '@@ -3,6 +3,6 @@',
        ' line 3', ' line 4', '-line 5', '-line 6', q{+}, q{+}, ' line 7', ' line 8'
    ],
);

for my $case (@cases) {
    my ( $original, $replacement, @expected ) = $case->@*;
    my ($first) = split /\n/, $original;
    is patch( $text, $original, $replacement ), hunk(@expected),
      "a change at $first has two lines of context where they exist";
}

is patch( "a\nb", 'b', 'c' ), hunk( '@@ -1,2 +1,2 @@', ' a', '-b', '+c' ), 'a file without a final newline';
is patch( "one\n", 'one', 'two' ), hunk( '@@ -1,1 +1,1 @@', '-one', '+two' ), 'a file of one line';

done_testing;
