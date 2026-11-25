use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use Raised;
use Test::Mutation::Mutant::Generator;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Source;
use Test::Mutation::Syntax::PPI;

sub generated ( $code, %select ) {
    my $source = Test::Mutation::Source->new( path => 'lib/X.pm', text => $code, encoding => 'UTF-8' );
    my @perl   = exists $select{perl} ? ( perl => delete $select{perl} ) : ();
    my $mutators =
      Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => [], disable => [], %select );
    return Test::Mutation::Mutant::Generator::generate(
        source   => $source,
        analysis => Test::Mutation::Syntax::PPI::analyze($source),
        mutators => $mutators,
        @perl,
    );
}

sub mutants ( $code, %select ) {
    return generated( $code, %select )->{mutants};
}

sub changes ( $code, $name, %select ) {
    return [ map { [ $_->original, $_->replacement ] } grep { $_->mutator eq $name } mutants( $code, %select )->@* ];
}

sub refused ( $code, %select ) {
    return [ map { [ $_->@{qw(mutator line rule)} ] } generated( $code, %select )->{rejected}->@* ];
}

subtest 'the generator refuses a change that breaks the file' => sub {
    is refused("sub f {\n    return 1 + 2;\n}\n"), [], 'a file whose changes all stand';

    my $returned = "sub f {\n    return <<\"T\";\ntext\nT\n}\n";
    is refused($returned), [ [ 'return-value', 2, 'here-document' ] ],
      'a removed return value would leave the text of its here-document behind';
    is changes( $returned, 'sub-body' ), [ [ "\n    return <<\"T\";\ntext\nT\n", "\n\n\n\n" ] ],
      'and the removed body takes the here-document as a whole';
    is refused("f(<<A);\nx\nA\ng();\n"), [ [ 'statement-removal', 1, 'here-document' ] ],
      'a removed statement likewise';

    my $declaring = "sub f {\n    chomp( my \$line = g() );\n    return \$line;\n}\n";
    is refused($declaring), [ [ 'statement-removal', 2, 'declaration' ] ],
      'a removed statement would take a declaration that later code names';
    is refused( "if ( open my \$log, '<', \$p ) { print {\$log} 1 }\n", enable => ['condition-fixed'] ),
      [ [ 'condition-fixed', 1, 'declaration' ], [ 'condition-fixed', 1, 'declaration' ] ],
      'and so would either fixed condition';

    my $module = "package A;\nsub f { 2 }\n1;\n";
    is refused( $module, enable => ['number-literal'] ), [ [ 'number-literal', 3, 'final-value' ] ],
      'the true value that ends a module stays';
    is changes( $module, 'number-literal', enable => ['number-literal'] ), [ [ '2', '3' ] ],
      'and another number changes';

    is refused( "my \$s = \"a\nb\";\n", enable => ['string-literal'] ), [ [ 'string-literal', 1, 'line-count' ] ],
      'an emptied string of two lines would move every later line';
    my $wrapped = "if (\$a) { f() }\nelsif ( my \$m = g() ) { h(\$m) }\n";
    is changes( $wrapped, 'condition-negation' ), [ [ 'if', 'unless' ], [ ' my $m = g() ', '!( my $m = g() )' ] ],
      'a negated condition keeps the declaration that it wraps';
    is changes( "my \$t = \$c ? <<A : \$d;\ntext\nA\n", 'condition-negation' ), [ [ '<<A : $d', '$d : <<A' ] ],
      'and a swap of branches keeps an introducer on its line';
    is refused("my \$t = \$c\n  ? <<A\ntext\nA\n  : \$d;\n"), [ [ 'condition-negation', 2, 'here-document' ] ],
      'a swap that moves an introducer to another line would read the next line as its text';
    is refused('f() if !!$x;'), [ [ 'negation', 1, 'same-result' ] ],
      'the second of two changes with one resulting text';
    is changes( 'f() if !!$x;', 'negation' ), [ [ q{!}, q{} ] ], 'and the first one stands';
};

subtest 'a change that calls a function names one that the file resolves' => sub {
    my $swap = sub ( $code, %select ) { return changes( $code, 'call-swap', %select ) };
    is $swap->("use List::Util qw(any);\nmy \$ok = any { \$_ } \@c;\n"), [ [ 'any', 'List::Util::all' ] ],
      'the module of the original provides the other name';
    is $swap->("use List::Util qw(any all);\nmy \$ok = any { \$_ } \@c;\n"), [ [ 'any', 'all' ] ],
      'the file imports the other name';
    is $swap->("my \$m = List::Util::max(\@b);\n"), [ [ 'List::Util::max', 'List::Util::min' ] ],
      'a qualified call keeps its package';
    is $swap->("push \@a, 1;\nmy \$s = lc \$t;\n"), [ [ 'push', 'unshift' ], [ 'lc', 'uc' ] ], 'core functions';
    is $swap->("my \$m = max(\@b);\n"),             [], 'a name of unknown origin has no swap';
    is refused("my \$m = max(\@b);\n"), [ [ 'call-swap', 1, 'unresolved-call' ] ], 'and the refusal names the rule';
    is $swap->("sub max { 1 }\nmy \$m = max(\@b);\n"), [],                      'a subroutine of the file has no swap';
    is $swap->("use POSIX;\nmy \$n = ceil(\$x);\n"),   [ [ 'ceil', 'floor' ] ], 'a default export';
    is $swap->("use List::Util qw(any);\nuse List::Util qw(all);\nmy \$ok = any { \$_ } \@c;\n"),
      [ [ 'any', 'List::Util::all' ] ], 'two statements may import into two scopes, so the module is named';
    is $swap->("CORE::push \@a, 1;\n"), [ [ 'CORE::push', 'CORE::unshift' ] ],
      'a core function under its qualified name';
    is $swap->("sub unshift { 1 }\npush \@a, 1;\n"), [ [ 'push', 'CORE::unshift' ] ],
      'a subroutine of the file with the other name, which the bare word would make ambiguous';
    is changes( "sub pop { 1 }\nmy \$s = shift \@a;\nmy \$t = CORE::pop \@a;\n", 'shift-pop', enable => ['shift-pop'] ),
      [ [ 'shift', 'CORE::pop' ], [ 'CORE::pop', 'CORE::shift' ] ], 'the other family of core functions likewise';

    my $boolean = sub ($code) { return changes( $code, 'boolean-literal' ) };
    is $boolean->("use v5.40;\nmy \$f = true;\n"), [ [ 'true', 'false' ] ], 'a boolean of the bundle';
    is $boolean->("use builtin qw(true);\nmy \$f = true;\n"), [ [ 'true', 'builtin::false' ] ],
      'a boolean that the file imports alone';
    is $boolean->("my \$f = true;\n"), [], 'a word that only looks like a boolean';

    my ($described) =
      grep { $_->mutator eq 'call-swap' } mutants("use List::Util qw(any);\nmy \$ok = any { \$_ } \@c;\n")->@*;
    is $described->description, 'replaced any with List::Util::all', 'the description names what the mutant holds';
};

subtest 'a swapped call compiles' => sub {
    my $code =
        "use strict;\nuse warnings;\nuse List::Util qw(any max);\nmy \@c = ( 1, 2 );\n"
      . "sub unshift { return 1 }\n"
      . "print 'some' if any { \$_ > 1 } \@c;\nprint max(\@c), List::Util::max(\@c);\npush \@c, 3;\n";
    my $source = Test::Mutation::Source->new( path => 'lib/X.pm', text => $code, encoding => 'UTF-8' );
    my @swaps  = grep { $_->mutator eq 'call-swap' } mutants($code)->@*;
    is [ map { $_->replacement } @swaps ], [ 'List::Util::all', 'List::Util::min', 'List::Util::min', 'CORE::unshift' ],
      'four swaps';
    for my $mutant (@swaps) {
        my $file = File::Temp->new( SUFFIX => '.pl' );
        print {$file} $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement ) or die "write: $!";
        close $file                                                                               or die "close: $!";
        my $path   = $file->filename;
        my $answer = qx{'$^X' -c '$path' 2>&1};
        is [ $?, $answer ], [ 0, "$path syntax OK\n" ], 'perl compiles the file with ' . $mutant->replacement;
    }
};

subtest 'operator families' => sub {
    is changes( '$a + $b - $c * $d / $e % $f ** $g;', 'arithmetic' ),
      [ [ '+', '-' ], [ '-', '+' ], [ '*', '/' ], [ '/', '*' ], [ '%', '*' ], [ '**', '*' ] ], 'arithmetic';
    is changes( 'f(-$a, +$b);', 'arithmetic' ), [], 'unary signs are left alone';
    is changes( '$a < $b; $a >= $b; $a == $b;', 'comparison' ),
      [ [ '<', '<=' ], [ '<', '>=' ], [ '>=', '>' ], [ '>=', '<' ], [ '==', '!=' ] ], 'comparison';
    is changes( '$a lt $b; $a eq $b;', 'string-comparison' ), [ [ 'lt', 'le' ], [ 'lt', 'ge' ], [ 'eq', 'ne' ] ],
      'string comparison';
    my $slurp = "my \$data = do {\n    local \$/;\n    open my (\$fh), '<:raw', \$path\n"
      . "      or die \"could not read file <\$path>\\n\";\n    <\$fh>;\n};\n";
    is changes( $slurp, 'comparison' ), [], 'a readline at the start of a statement is no comparison';
    is changes( '$a && $b || $c // $d; f() or g() and h(); $e xor $f; $g ^^ $h;', 'logical' ),
      [
        [ '&&',  '||' ],
        [ '||',  '&&' ],
        [ '//',  '||' ],
        [ 'or',  'and' ],
        [ 'and', 'or' ],
        [ 'xor', 'or' ],
        [ '^^',  '||' ]
      ],
      'logical, with the exclusive or of both precedences';
    is changes( 'my $m = $a & $b | $c ^ $d << 1 >> 2; $e &= 1; $f |= 2; $g ^= 3; $h <<= 1; my $n = ~$i;', 'bitwise' ),
      [
        [ q{&},  q{|} ],
        [ q{|},  q{&} ],
        [ q{^},  q{&} ],
        [ '<<',  '>>' ],
        [ '>>',  '<<' ],
        [ '&=',  '|=' ],
        [ '|=',  '&=' ],
        [ '^=',  '&=' ],
        [ '<<=', '>>=' ],
        [ q{~},  q{} ],
      ],
      'bitwise operators, their assignments, and the complement';
    is changes( 'use feature q(bitwise); my $s = $a &. $b |. $c ^. $d; $e &.= $f; my $t = ~.$g;', 'bitwise' ),
      [ [ '&.', '|.' ], [ '|.', '&.' ], [ '^.', '&.' ], [ '&.=', '|.=' ], [ '~.', q{} ] ],
      'and their string forms';
    is changes( 'my @bits = ( 1 << 0, 0x20 >> 0, 1 << 2, $mask >> 0, 2 << 0 + $n );', 'bitwise' ),
      [ [ '<<', '>>' ], [ '>>', '<<' ], [ '<<', '>>' ] ],
      'only shifts of a literal by a literal zero have the same result in either direction';
    is changes( 'my @n = ( -$x, - $y, -1, 2 - 1, -bare => 1, $z ** -0.5 );', 'unary-minus' ),
      [ [ q{-}, q{} ], [ q{-}, q{} ], [ '-1', '1' ], [ '-0.5', '0.5' ] ],
      'a unary minus and a negative number lose their sign, and a subtraction and a dashed word stay';
    my $postfix = 'sub last_pair { return 0 .. $array->$#*-1 } sub size { $array->@* -2 }';
    is changes( $postfix, 'unary-minus' ), [], 'a subtraction after a postfix dereference keeps its minus';
    is changes( $postfix, 'arithmetic' ), [ [ '-', '+' ], [ '-', '+' ] ],
      'both subtractions expose their operator alone';
    is changes( $postfix, 'number-literal', enable => ['number-literal'] ),
      [ [ '0', '1' ], [ '1', '0' ], [ '2', '3' ] ], 'each subtrahend is an unsigned literal';
    my $subtractions = 'sub f { return $_[0]-1, g($x)-2, ($x)-3, [$x]-4, $x++-5, $x---6, 0 .. -7 }';
    is changes( $subtractions, 'unary-minus' ), [ [ '-7', '7' ] ],
      'a negative range endpoint is distinct from a subtrahend after a completed operand';
    is changes( $subtractions, 'arithmetic' ), [ ( [ '-', '+' ] ) x 6 ],
      'subscripts, parenthesized calls, constructors, and postfix updates end before the subtraction sign';
    is changes( '$i++; --$j;', 'increment' ), [ [ '++', '--' ], [ '--', '++' ] ], 'increment';
    is changes( '$a += 1; $b .= "x"; $c //= 2; $d = 3;', 'assignment' ),
      [ [ '+=', '-=' ], [ '.=', '=' ], [ '//=', '||=' ] ],
      'assignment';
    is changes( 'f() if !$a; g() unless not $b;', 'negation' ), [ [ '!', q{} ], [ 'not', q{} ] ], 'negation';
    is changes( '$a =~ /x/; $b !~ /y/; $c =~ s/x/y/; $d =~ tr/a/b/;', 'match' ), [ [ '=~', '!~' ], [ '!~', '=~' ] ],
      'match negation skips substitution and transliteration';
};

subtest 'word families' => sub {
    is changes( 'if ($a) { f() } g() unless $b; while ($c) { h() } i() until $d;', 'condition-negation' ),
      [ [ 'if', 'unless' ], [ 'unless', 'if' ], [ 'while', 'until' ], [ 'until', 'while' ] ], 'conditional keywords';
    is changes(
        "if (\$a) { f() }\nelsif ( \$b > 1 ) { g() }\nmy \$v = \$c ? \$d + 1 : h(\$e), 2;\n",
        'condition-negation'
      ),
      [ [ 'if', 'unless' ], [ ' $b > 1 ', '!( $b > 1 )' ], [ '$d + 1 : h($e)', 'h($e) : $d + 1' ] ],
      'an elsif condition is negated, and the branches of a conditional swap';
    is changes( 'for (@a) { next if $_; last; redo }', 'loop-control' ),
      [ [ 'next', 'last' ], [ 'last', 'next' ], [ 'redo', 'next' ] ], 'loop control, where a redo becomes a next';
    is changes( 'my @t = ( defined $x, exists $h{a}, wantarray, -e $p, -s $q > 1, ref $r, - $s );', 'predicate' ),
      [
        [ 'defined',   '!defined' ],
        [ 'exists',    '!exists' ],
        [ 'wantarray', '!wantarray' ],
        [ '-e',        '!-e' ],
        [ '-s',        '!-s' ]
      ],
      'a test of definedness, existence, context, or a file is negated';
    my $imports = "use v5.40;\nuse List::Util qw(max min any all);\n";
    is changes( $imports . 'push @a, max(@b); my %h = ( min => 1 ); $o->uc; any { $_ } @c;', 'call-swap' ),
      [ [ 'push', 'unshift' ], [ 'max', 'min' ], [ 'any', 'all' ] ], 'call swaps skip hash keys and methods';
    is changes( $imports . 'return true; my $f = false;', 'boolean-literal' ),
      [ [ 'true', 'false' ], [ 'false', 'true' ] ], 'booleans';
    is changes( 'my $s = shift;', 'shift-pop' ), [], 'shift-pop is off by default';
    is changes( 'my $s = shift;', 'shift-pop', enable => ['shift-pop'] ), [ [ 'shift', 'pop' ] ],
      'shift-pop when enabled';
};

subtest 'structural mutators' => sub {
    is changes( "sub f {\n    return 1 if \$x;\n    return 0;\n    return \$y + 1;\n    return;\n}\n", 'return-value' ),
      [ [ '1', '0' ], [ '0', '1' ], [ '$y + 1', q{} ] ], 'return values';
    is changes( "sub f {\n    log_it(\n        1,\n    );\n    return 1;\n}\n", 'statement-removal' ),
      [ [ "log_it(\n        1,\n    );", "\n\n" ] ], 'a removed statement leaves its line breaks';
    my $closing = "sub f {\n    log_it(1);\n    close \$out or die 'x';\n    closedir \$dir;\n    return 1;\n}\n";
    is changes( $closing, 'statement-removal' ), [ [ 'log_it(1);', q{} ] ],
      'the default profile leaves a close statement in place';
    is changes( $closing, 'close-removal', profile => 'extended' ),
      [ [ q{close $out or die 'x';}, q{} ], [ 'closedir $dir;', q{} ] ],
      'the extended profile removes a close and a closedir statement';
    is changes( $closing, 'close-removal' ), [], 'and the default profile has no such mutator';
    my $qualified = "sub f {\n    CORE::close(\$out);\n    CORE::closedir \$dir;\n    close_all();\n    return 1;\n}\n";
    is changes( $qualified, 'statement-removal' ), [ [ 'close_all();', q{} ] ],
      'a close under its qualified name stays in place, and a sub with a similar name is removed';
    is changes( $qualified, 'close-removal', profile => 'extended' ),
      [ [ 'CORE::close($out);', q{} ], [ 'CORE::closedir $dir;', q{} ] ],
      'the extended profile removes the qualified forms';
    is changes( "sub f {\n    g();\n}\nsub h { 1 }\nsub empty { }\n", 'sub-body' ),
      [ [ "\n    g();\n", "\n\n" ], [ ' 1 ', q{} ] ],
      'sub bodies';
};

subtest 'extended mutators' => sub {
    my %extended = ( profile => 'extended' );
    is changes( 'my @a = ( 0, 1, 41, 1.5, 0x10 );', 'number-literal', %extended ),
      [ [ '0', '1' ], [ '1', '0' ], [ '41', '42' ] ],
      'integer literals';
    is changes( q{my @s = ( 'abc', "", q{def}, qq<g$h> );}, 'string-literal', %extended ),
      [ [ q{'abc'}, q{''} ], [ q{""}, q{"mutant"} ], [ 'q{def}', 'q{}' ], [ 'qq<g$h>', 'qq<>' ] ],
      'string literals in quotes and under a quote operator';
    is changes( 'if ($a) { f() } while ($b) { g() } until ($c) { h() }', 'condition-fixed', %extended ),
      [ [ '$a', '1' ], [ '$a', '0' ], [ '$b', '0' ], [ '$c', '1' ] ], 'fixed conditions avoid endless loops';
    is changes( 'my @s = sort { $a <=> $b } @n; my %h = ( sort => 1 ); $o->sort;', 'sort-order', %extended ),
      [ [ 'sort', 'reverse sort' ] ], 'a sort call is reversed, and a key or a method is left alone';
    is changes( 'for my $i ( 1 .. $n ) { f($i) } my $s = $a . $b;', 'range-boundary', %extended ),
      [ [ '..', '.. -1 +' ] ], 'the upper bound of a range moves down by one';
    my $patterns = 'f() if $x =~ /^ab+c*d?$/i; $y =~ s/\Afoo\z/b+r/g; my $r = qr/a{2,3}[+*^]\$(?i)z+?/msix;';
    is changes( $patterns, 'regex-anchor', %extended ), [ [ '^', q{} ], [ '$', q{} ], [ '\A', q{} ], [ '\z', q{} ] ],
      'anchors are removed, and an escaped or bracketed character is left alone';
    is changes( $patterns, 'regex-quantifier', %extended ), [ [ '+', '*' ], [ '*', '+' ], [ '?', q{} ], [ '+', '*' ] ],
      'quantifiers change, and a replacement or a repetition count is left alone';
    is changes( $patterns, 'regex-flag', %extended ), [ [ 'i', q{} ], [ 'i', q{} ] ],
      'the case flag is removed from the trailing flags';
    is changes( 'my $n = 41;', 'number-literal' ), [], 'extended mutators are off in the default profile';
};

subtest 'mutants carry positions, identities, and suppression' => sub {
    my $code = join "\n", 'my $a = 1 + 2;', 'my $b = 3 + 4;    ## no mutate',
      'my $c = 5 - 6;    ## no mutate (comparison)',
      'my $d = 7 * 8;    ## no mutate (comparison, arithmetic)', q{};
    my @mutants = mutants($code)->@*;
    is [ map { [ $_->from, $_->to, $_->suppressed ] } @mutants ],
      [
        [ [ 1, 11 ], [ 1, 12 ], 0 ],
        [ [ 2, 11 ], [ 2, 12 ], 1 ],
        [ [ 3, 11 ], [ 3, 12 ], 0 ],
        [ [ 4, 11 ], [ 4, 12 ], 1 ]
      ],
      'positions, and the comments of the second and the fourth line';
    my %ids = map { $_->id => 1 } @mutants;
    is scalar( keys %ids ),                   4,                           'identifiers are distinct';
    is [ map { $_->id } mutants($code)->@* ], [ map { $_->id } @mutants ], 'identifiers are stable across runs';

    my $reasons = join "\n", 'my $e = 1 - 2 > 0;    ## no mutate (comparison): the bound is fixed',
      '## no mutate: a block', 'my $f = 3 + 4;    ## no mutate (arithmetic)', 'my $g = 5 * 6;', '## use mutate', q{};
    is [ map { [ $_->from->[0], $_->mutator, $_->suppressed, $_->suppression_reason ] } mutants($reasons)->@* ],
      [
        [ 1, 'arithmetic', 0, undef ],
        [ 1, 'comparison', 1, 'the bound is fixed' ],
        [ 1, 'comparison', 1, 'the bound is fixed' ],
        [ 3, 'arithmetic', 1, undef ],
        [ 4, 'arithmetic', 1, 'a block' ],
      ],
      'a mutant keeps the reason of the last comment that covers it';
};

subtest 'a mutant knows whether the compiled code shows it' => sub {
    my $code = "class Counter {\n    field \$step = 1 + 1;\n    method bump { \$step - 1 }\n}\n";
    is [ map { [ $_->original, $_->comparable ] } grep { $_->mutator eq 'arithmetic' } mutants($code)->@* ],
      [ [ '+', 0 ], [ '-', 1 ] ], 'a mutant of a field is not comparable';
};

subtest 'an arithmetic change without effect yields no mutant' => sub {
    is changes( '$a + 0; $b - 0; $c * 1; $d / 1; $e ** 1; $f + 0.0;', 'arithmetic' ), [],
      'zero added or subtracted, and one as a factor, a divisor, or an exponent';
    is changes( '$a + 1; $b * 0; 0 + $c; 1 * $d; $e % 1; $f + 0 * $g; $h - 0 if $i;', 'arithmetic' ),
      [ [ '+', '-' ], [ '*', '/' ], [ '+', '-' ], [ '*', '/' ], [ '%', '*' ], [ '+', '-' ], [ '*', '/' ] ],
      'another number, another side, another operator, and a number that belongs to a tighter operator';
};

subtest 'a comparison with the version of Perl keeps its boundary on another version' => sub {
    my $code = 'f() if $] < 5.010; g() if "$]" >= 5.036; h() if 5.008 > $]; i() if $] <= 5.012001;';
    is changes( $code, 'comparison', perl => 5.044 ),
      [ [ '<', '>=' ], [ '>=', '<' ], [ '>', '<=' ], [ '<=', '>' ] ],
      'the tests run on another version, so the boundary changes nothing and the negation stays';
    is changes( $code, 'comparison', perl => 5.036 ),
      [ [ '<', '>=' ], [ '>=', '>' ], [ '>=', '<' ], [ '>', '<=' ], [ '<=', '>' ] ],
      'the tests run on the named version, so the boundary of that comparison decides';
    is scalar( changes( $code, 'comparison' )->@* ), 8, 'without the version of the tests every change stays';
    is changes( 'f() if $n < 5.010; g() if $] < $least;', 'comparison', perl => 5.044 ),
      [ [ '<', '<=' ], [ '<', '>=' ], [ '<', '<=' ], [ '<', '>=' ] ],
      'another variable or no literal leaves the comparison as it is';
};

subtest 'two mutators with the same replacement yield one mutant' => sub {
    my @mutants = mutants( 'sub f { return 1 }', profile => 'extended' )->@*;
    is [ map { [ $_->mutator, $_->original, $_->replacement ] } grep { $_->original eq '1' } @mutants ],
      [ [ 'return-value', '1', '0' ] ], 'the first mutator is credited';

    my $source = Test::Mutation::Source->new( path => 'lib/X.pm', text => '$a + $b;', encoding => 'UTF-8' );
    my @proposed =
      ( [ first => [q{-}] ], [ second => [ q{-}, q{*} ] ], [ third => [ q{*}, q{/} ] ], [ fourth => [ q{+}, q{%} ] ] );
    my $proposing = sub ( $name, $replacements ) {
        return Test::Mutation::Mutator->new(
            name        => $name,
            profile     => 'default',
            description => 'a test mutator',
            generate    => sub ($site) {
                return if $site->text ne q{+};
                return map { { replacement => $_, description => "to $_" } } $replacements->@*;
            },
        );
    };
    my $generated = Test::Mutation::Mutant::Generator::generate(
        source   => $source,
        analysis => Test::Mutation::Syntax::PPI::analyze($source),
        mutators => [ map { $proposing->( $_->@* ) } @proposed ],
    );
    is [ map { [ $_->mutator, $_->replacement ] } $generated->{mutants}->@* ],
      [ [ 'first', q{-} ], [ 'second', q{*} ], [ 'third', q{/} ], [ 'fourth', q{%} ] ],
      'a mutator keeps its later replacements after one that an earlier mutator proposed';
    is [ map { [ $_->@{qw(mutator line rule)} ] } $generated->{rejected}->@* ],
      [ [ 'second', 1, 'same-result' ], [ 'third', 1, 'same-result' ], [ 'fourth', 1, 'same-text' ] ],
      'the generator lists what it refused in the order of the proposals, and no mutator drops a proposal itself';
};

subtest 'selection' => sub {
    my @default =
      map { $_->name }
      Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => [], disable => [] )->@*;
    my @extended =
      map { $_->name }
      Test::Mutation::Mutator::Catalog::choose( profile => 'extended', enable => [], disable => [] )->@*;
    is scalar(@extended), scalar( Test::Mutation::Mutator::Catalog::mutators()->@* ),
      'the extended profile holds every mutator';
    ok scalar(@default) < scalar(@extended), 'the default profile is a subset';
    is [
        grep { $_ eq 'arithmetic' }
        map  { $_->name }
          Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => [], disable => ['arithmetic'] )->@*
      ],
      [], 'a disabled mutator is removed';
    is Raised::error(
        sub {
            Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => [qw(nope none)], disable => [] );
        }
      ),
      [ 'usage', 'mutator-unknown', 'unknown mutator: nope, none' ], 'unknown names are refused together';
};

subtest 'every mutant of the corpus changes its span alone' => sub {
    my @broken;
    my $count = 0;
    for my $path ( sort glob 't/corpus/modern/*.pm' ) {
        open my $handle, '<:raw', $path or die "open $path: $!";
        my $bytes   = do { local $/ = undef; readline $handle };
        my $source  = Test::Mutation::Source->from_bytes( path => $path, bytes => $bytes );
        my $text    = $source->text;
        my $mutants = Test::Mutation::Mutant::Generator::generate(
            source   => $source,
            analysis => Test::Mutation::Syntax::PPI::analyze($source),
            mutators => Test::Mutation::Mutator::Catalog::mutators(),
        );
        for my $mutant ( $mutants->{mutants}->@* ) {
            $count++;
            my $mutated  = $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement );
            my $expected = substr( $text, 0, $mutant->start ) . $mutant->replacement . substr( $text, $mutant->end );
            push @broken, $mutant->id
              if $mutated ne $expected
              || substr( $text, $mutant->start, $mutant->end - $mutant->start ) ne $mutant->original
              || $mutated eq $text;
        }
    }
    is \@broken, [], 'no mutant touches text outside its span';
    ok $count > 100, "the corpus yields mutants ($count)";
};

done_testing;
