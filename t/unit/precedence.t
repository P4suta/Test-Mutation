use v5.36;
use Test2::V0;
use lib 't/lib';
use Bounded;
use Test::Mutation::Syntax::Precedence;

# The table of perlop decides how far each operand of an operator reaches.
# A token list here holds the kind and the text of each token, as the analysis builds it from the parser.

# A token list from a text with one token for each word of it.
# A bracket stands for a structure, a word in the table of words for a word, and a semicolon for a stop.
sub items ($text) {
    return [
        map {
                /\A[(]/                                                               ? [ 'list',      '()' ]
              : /\A[[]/                                                               ? [ 'subscript', '[]' ]
              : /\A[{]/                                                               ? [ 'block',     '{}' ]
              : $_ eq q{;}                                                            ? [ 'stop',      q{;} ]
              : /\A(?:\\|\@|%|\$\#)\z/                                                ? [ 'cast',      $_ ]
              : /\A[\$\@%&]\w|\A\d/                                                   ? [ 'term',      $_ ]
              : /\A'/                                                                 ? [ 'term',      $_ ]
              : /\A[[:alpha:]_]/ && !/\A(?:x|lt|gt|le|ge|eq|ne|cmp|and|or|xor|not)\z/ ? [ 'word',      $_ ]
              : [ 'operator', $_ ]
        } split q{ },
        $text
    ];
}

sub parsed ($text) {
    local $SIG{__WARN__} = sub ($warning) { bail_out("the precedence parser warned for $text: $warning") };
    my ( $ended, $parsed ) = Bounded::ended( 1, sub { Test::Mutation::Syntax::Precedence::parse( items($text) ) } );
    bail_out("the precedence parser did not finish for $text") if !$ended;
    return $parsed;
}

# The text of each operand of each operator, in the order of the tokens.
sub operands ($text) {
    my @tokens = split q{ }, $text;
    my $parsed = parsed($text);
    my @found;
    for my $index ( 0 .. $#tokens ) {
        my $record = $parsed->[$index] or next;
        my @parts =
          map { exists $record->{$_} ? "$_=" . join q{ }, @tokens[ $record->{$_}[0] .. $record->{$_}[1] - 1 ] : () }
          qw(before middle after);
        push @found, join q{ }, $tokens[$index], $record->{position}, map { "[$_]" } @parts;
    }
    return \@found;
}

subtest 'the table holds every level of perlop from the tightest to the loosest' => sub {
    my @levels = Test::Mutation::Syntax::Precedence::levels()->@*;
    is scalar @levels, 24, 'twenty-four levels below the terms';
    is [ map { $_->{associativity} } @levels[ 0, 3, 8, 10, 11, 17, 23 ] ],
      [qw(left right nonassoc chained chain/na right left)], 'each level with its associativity';
    is $levels[0]{infix},  ['->'],         'the arrow binds tightest';
    is $levels[23]{infix}, [qw(or xor)],   'or and xor bind loosest';
    is $levels[15]{infix}, [qw(|| ^^ //)], 'the logical or of Perl 5.40 stands beside the defined or';
    ok( ( grep { $_ eq 'defined' } $levels[8]{prefix}->@* ), 'a named unary operator stands at its level' );
    ok( ( grep { $_ eq '-e' } $levels[8]{prefix}->@* ),      'and so does a file test' );
    ok( ( grep { $_ eq 'print' } $levels[20]{prefix}->@* ),  'a list operator stands below the comma' );
};

subtest 'an operand reaches as far as the operators that bind tighter' => sub {
    is operands('$a + $b * $c'), [ '+ infix [before=$a] [after=$b * $c]', '* infix [before=$b] [after=$c]' ],
      'a product inside a sum';
    is operands('$a - $b + $c'), [ '- infix [before=$a] [after=$b]', '+ infix [before=$a - $b] [after=$c]' ],
      'a left associative chain';
    is operands('$a ** $b ** $c'), [ '** infix [before=$a] [after=$b ** $c]', '** infix [before=$b] [after=$c]' ],
      'a right associative chain';
    is operands('$a = $b = 1'), [ '= infix [before=$a] [after=$b = 1]', '= infix [before=$b] [after=1]' ],
      'an assignment is right associative';
    is operands('- $a ** 2'), [ '- prefix [after=$a ** 2]', '** infix [before=$a] [after=2]' ],
      'the power binds tighter than a minus before it';
    is operands('! $a == $b'), [ '! prefix [after=$a]', '== infix [before=! $a] [after=$b]' ],
      'a negation binds tighter than a comparison';
    is operands('not $a == $b'), [ 'not prefix [after=$a == $b]', '== infix [before=$a] [after=$b]' ],
      'and the word not binds looser';
};

subtest 'a word reaches as far as its class lets it' => sub {
    is operands('defined $a || $b'), [ 'defined prefix [after=$a]', '|| infix [before=defined $a] [after=$b]' ],
      'a named unary operator takes what binds tighter than it';
    is operands('length $a + 1 < $b'),
      [ 'length prefix [after=$a + 1]', '+ infix [before=$a] [after=1]', '< infix [before=length $a + 1] [after=$b]' ],
      'and a sum binds tighter than it';
    is operands('length () + 1'), ['+ infix [before=length ()] [after=1]'],
      'a parenthesis after the name makes the call a term';
    is operands('-e $f && $g'), [ '-e prefix [after=$f]', '&& infix [before=-e $f] [after=$g]' ],
      'a file test binds as a named unary operator';
    is operands('print $a , $b or die'),
      [
        'print prefix [after=$a , $b]',
        ', infix [before=$a] [after=$b]',
        'or infix [before=print $a , $b] [after=die]'
      ],
      'a list operator takes the whole list';
    is operands('time - $a'), ['- infix [before=time] [after=$a]'], 'a function without an argument is a term';
    is operands('return - $a'), [ 'return prefix [after=- $a]', '- prefix [after=$a]' ],
      'a sign after a word that takes an argument starts the argument';
    is operands('LIMIT - $a'), ['- infix [before=LIMIT] [after=$a]'],
      'a word of the project before an operator is a term, as a constant is';
    is operands('croak () - $a'), ['- infix [before=croak ()] [after=$a]'],
      'a parenthesized call of an unknown word is a term';
    is operands('goto () + $n'), [ 'goto prefix [after=() + $n]', '+ infix [before=()] [after=$n]' ],
      'a parenthesized operand of goto can belong to a larger expression';
    is operands('croak $a , $b or $c'),
      [ 'croak prefix [after=$a , $b]', ', infix [before=$a] [after=$b]',
        'or infix [before=croak $a , $b] [after=$c]' ],
      'and a word of the project before a term takes a list';
    is operands('my $a = $b'), ['= infix [before=my $a] [after=$b]'], 'a declaration is a term';
};

subtest 'the conditional operator pairs its colon at the depth of its siblings' => sub {
    is operands('$c ? $a : $b'), ['? infix [before=$c] [middle=$a] [after=$b]'], 'a conditional';
    is operands('$x = $c ? $a : $b , $y'),
      [
        '= infix [before=$x] [after=$c ? $a : $b]',
        '? infix [before=$c] [middle=$a] [after=$b]',
        ', infix [before=$x = $c ? $a : $b] [after=$y]'
      ],
      'the second branch stops before a comma';
    is operands('$c ? $a : $d ? $e : $f'),
      [ '? infix [before=$c] [middle=$a] [after=$d ? $e : $f]', '? infix [before=$d] [middle=$e] [after=$f]' ],
      'a conditional in the second branch belongs to it';
    is operands('$c ? $d ? $e : $f : $g'),
      [ '? infix [before=$c] [middle=$d ? $e : $f] [after=$g]', '? infix [before=$d] [middle=$e] [after=$f]' ],
      'and a conditional in the first branch takes the nearer colon';
    is operands('$c ? $a : $b or $y'),
      [ '? infix [before=$c] [middle=$a] [after=$b]', 'or infix [before=$c ? $a : $b] [after=$y]' ],
      'the second branch stops before a low or';
    is operands('$c ? $a : $b = 1'),
      [ '? infix [before=$c] [middle=$a] [after=$b]', '= infix [before=$c ? $a : $b] [after=1]' ],
      'and before an assignment';
    is operands('$c ? $a + 1 : $b . $d'),
      [
        '? infix [before=$c] [middle=$a + 1] [after=$b . $d]',
        '+ infix [before=$a] [after=1]',
        '. infix [before=$b] [after=$d]'
      ],
      'and it holds what binds tighter';
    is operands('$c ? $a ;'),   ['? infix [before=$c]'], 'a conditional without its colon pairs with nothing';
    is operands('$c ? $a : ;'), ['? infix [before=$c]'], 'and one without its second branch';
    is operands('$c ? : $a + 1'), [ '? infix [before=$c]', '+ infix [before=$a] [after=1]' ],
      'a colon immediately following a question mark cannot supply a first branch';
    is operands('$c ? $a ; $b + 1'), [ '? infix [before=$c]', '+ infix [before=$b] [after=1]' ],
      'a stop after the first branch leaves the following expression independent';
};

subtest 'a record holds the level of its operator' => sub {
    my $parsed = parsed('$c ? $a = 1 : $b');
    my @levels = Test::Mutation::Syntax::Precedence::levels()->@*;
    is [ map { $_ ? $_->{level} : () } $parsed->@* ], [ scalar(@levels) - 17, scalar(@levels) - 18 ],
      'the conditional binds tighter than the assignment in its first branch';
};

subtest 'a term takes its subscripts, its arrows, and its calls' => sub {
    is operands('$x -> [] + 1'), [ '-> infix [before=$x] [after=[]]', '+ infix [before=$x -> []] [after=1]' ],
      'an arrow takes a subscript';
    is operands('$o -> m () - 1'), [ '-> infix [before=$o] [after=m ()]', '- infix [before=$o -> m ()] [after=1]' ],
      'and a method with its arguments';
    is operands('$o -> ; - 1'), [ '-> infix [before=$o]', '- prefix [after=1]' ],
      'an arrow without a target takes nothing';
    is operands('$a [] [] - 1'), ['- infix [before=$a [] []] [after=1]'], 'a variable takes its subscripts';
    is operands('@ $x + 1'),     ['+ infix [before=@ $x] [after=1]'],     'a sigil takes the term after it';
    is operands('$# {} - 1'),    ['- infix [before=$# {}] [after=1]'],    'and the block after it';
    is operands('do {} + 1'),    ['+ infix [before=do {}] [after=1]'],    'a do block is a term';
    is operands('do $f + 1'), [ 'do prefix [after=$f + 1]', '+ infix [before=$f] [after=1]' ],
      'and a do of a file is a named unary operator';
    is operands('sub () {} + 1'), ['+ infix [before=sub () {}] [after=1]'], 'an anonymous subroutine is a term';
    is operands('sub - 1'),       ['- infix [before=sub] [after=1]'],       'and the word alone is a term';
    is operands('time () - 1'), ['- infix [before=time ()] [after=1]'],
      'a function without operands takes its parentheses';
    is operands('print () - 1'), ['- infix [before=print ()] [after=1]'], 'and so does a list operator';
};

subtest 'an operator before its operand' => sub {
    is operands('++ $a + 1'), [ '++ prefix [after=$a]', '+ infix [before=++ $a] [after=1]' ], 'an increment';
    is operands('++ $h -> [] ** 2'),
      [ '++ prefix [after=$h -> []]', '-> infix [before=$h] [after=[]]', '** infix [before=++ $h -> []] [after=2]' ],
      'the arrow binds more tightly than prefix increment and exponentiation binds less tightly';
    is operands('\\ $a ** 2'), ['** infix [before=$a] [after=2]'], 'a reference takes the power';
    is operands('$x = \\ $a ** 2'), [ '= infix [before=$x] [after=\ $a ** 2]', '** infix [before=$a] [after=2]' ],
      'a reference after an assignment takes its operand on the right';
    is operands('@ $a ** 2'), ['** infix [before=@ $a] [after=2]'], 'an array dereference is the base of the power';
    is operands('! ;'),       ['! prefix'],                         'a negation without an operand';
    is operands('-e ; 1'),    ['-e prefix'],                        'a file test without one';
    is operands('-e () . $x || $y'),
      [ '-e prefix [after=() . $x]', '. infix [before=()] [after=$x]', '|| infix [before=-e () . $x] [after=$y]' ],
      'a file test takes what follows its parentheses';
    is operands('last LABEL if $x'), ['last prefix [after=LABEL]'], 'a loop control takes its label';
    is operands('next if $x'),       [],                            'or nothing';
    is operands('goto $a ? $b : $c'),
      [ 'goto prefix [after=$a ? $b : $c]', '? infix [before=$a] [middle=$b] [after=$c]' ],
      'a goto takes what binds tighter than an assignment';
    is operands('defined ;'),  [],                                    'a named unary operator without an operand';
    is operands('$x isa Foo'), ['isa infix [before=$x] [after=Foo]'], 'a word between two operands';
    is operands('print {} $a , $b'), [ 'print prefix [after={} $a , $b]', ', infix [before=$a] [after=$b]' ],
      'a list operator takes a block before its list';
};

subtest 'the parse ends on every token list' => sub {
    is operands(': ? , => ;'), [],                                 'a list of operators that start nothing';
    is operands('$a $b + $c'), ['+ infix [before=$b] [after=$c]'], 'two terms side by side';
    is operands('$a ++ + $b'), [ '++ postfix [before=$a]', '+ infix [before=$a ++] [after=$b]' ],
      'an increment after its operand';
    is operands('\\ $a'), [], 'a reference is no operator of the table';
};

subtest 'a token that starts an operand' => sub {
    ok Test::Mutation::Syntax::Precedence::starts_operand($_), "$_ starts an operand" for qw(- + ! ~ ++ -e not);
    ok !Test::Mutation::Syntax::Precedence::starts_operand($_), "$_ does not" for qw(> * . or : ? =>), q{,};
};

done_testing;
