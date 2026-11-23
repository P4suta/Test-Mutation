use v5.36;
use Test2::V0;
use Test::Mutation::Mutant::Generator;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Source;
use Test::Mutation::Syntax::PPI;

sub mutants ( $code, %select ) {
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

sub changes ( $code, $name, %select ) {
    return [ map { [ $_->original, $_->replacement ] } grep { $_->mutator eq $name } mutants( $code, %select )->@* ];
}

subtest 'operator families' => sub {
    is changes( '$a + $b - $c * $d / $e % $f ** $g;', 'arithmetic' ),
      [ [ '+', '-' ], [ '-', '+' ], [ '*', '/' ], [ '/', '*' ], [ '%', '*' ], [ '**', '*' ] ], 'arithmetic';
    is changes( 'f(-$a, +$b);', 'arithmetic' ), [], 'unary signs are left alone';
    is changes( '$a < $b; $a >= $b; $a == $b;', 'comparison' ),
      [ [ '<', '<=' ], [ '<', '>=' ], [ '>=', '>' ], [ '>=', '<' ], [ '==', '!=' ] ], 'comparison';
    is changes( '$a lt $b; $a eq $b;', 'string-comparison' ), [ [ 'lt', 'le' ], [ 'lt', 'ge' ], [ 'eq', 'ne' ] ],
      'string comparison';
    is changes( '$a && $b || $c // $d; f() or g() and h();', 'logical' ),
      [ [ '&&', '||' ], [ '||', '&&' ], [ '//', '||' ], [ 'or', 'and' ], [ 'and', 'or' ] ], 'logical';
    is changes( '$i++; --$j;', 'increment' ), [ [ '++', '--' ], [ '--', '++' ] ], 'increment';
    is changes( '$a += 1; $b .= "x"; $c //= 2; $d = 3;', 'assignment' ),
      [ [ '+=', '-=' ], [ '.=', '=' ], [ '//=', '||=' ] ],
      'assignment';
    is changes( 'f() if !$a; g() unless not $b;', 'negation' ), [ [ '!', q{} ], [ 'not', q{} ] ], 'negation';
    is changes( '$a =~ /x/; $b !~ /y/; $c =~ s/x/y/; $d =~ tr/a/b/;', 'match' ), [ [ '=~', '!~' ], [ '!~', '=~' ] ],
      'match negation skips substitution and transliteration';
};

subtest 'word families' => sub {
    is changes( 'if ($a) { f() } g() unless $b; while ($c) { h() } i() until $d;', 'conditional-keyword' ),
      [ [ 'if', 'unless' ], [ 'unless', 'if' ], [ 'while', 'until' ], [ 'until', 'while' ] ], 'conditional keywords';
    is changes( 'for (@a) { next if $_; last; }', 'loop-control' ), [ [ 'next', 'last' ], [ 'last', 'next' ] ],
      'loop control';
    is changes( 'push @a, max(@b); my %h = ( min => 1 ); $o->uc; any { $_ } @c;', 'call-swap' ),
      [ [ 'push', 'unshift' ], [ 'max', 'min' ], [ 'any', 'all' ] ], 'call swaps skip hash keys and methods';
    is changes( 'return true; my $f = false;', 'boolean-literal' ), [ [ 'true', 'false' ], [ 'false', 'true' ] ],
      'booleans';
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
    is changes( q{my @s = ( 'abc', "", q{def} );}, 'string-literal', %extended ),
      [ [ q{'abc'}, q{''} ], [ q{""}, q{"mutant"} ] ],
      'string literals';
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

    my $source    = Test::Mutation::Source->new( path => 'lib/X.pm', text => '$a + $b;', encoding => 'UTF-8' );
    my @proposed  = ( [ first => [q{-}] ], [ second => [ q{-}, q{*} ] ], [ third => [ q{*}, q{/} ] ] );
    my $generated = Test::Mutation::Mutant::Generator::generate(
        source   => $source,
        analysis => Test::Mutation::Syntax::PPI::analyze($source),
        mutators => [
            map {
                my ( $name, $replacements ) = $_->@*;
                Test::Mutation::Mutator->new(
                    name        => $name,
                    profile     => 'default',
                    description => 'a test mutator',
                    generate    => sub ($site) {
                        return if $site->text ne q{+};
                        return map { { replacement => $_, description => "to $_" } } $replacements->@*;
                    },
                )
            } @proposed
        ],
    );
    is [ map { [ $_->mutator, $_->replacement ] } $generated->@* ],
      [ [ 'first', q{-} ], [ 'second', q{*} ], [ 'third', q{/} ] ],
      'a mutator keeps its later replacements after one that an earlier mutator proposed';
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
    like dies { Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => ['nope'], disable => [] ) },
      qr/unknown mutator: nope/, 'an unknown name is refused';
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
        for my $mutant ( $mutants->@* ) {
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
