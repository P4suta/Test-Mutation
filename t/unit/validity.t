use v5.36;
use Test2::V0;
use Test::Mutation::Mutant::Validity;
use Test::Mutation::Site;

# Every mutant passes one boundary, whatever mutator proposed it.
# The rules there keep a change from breaking the file in a way that no test of the project is about.

sub site ( $text, $start, %fields ) {
    return Test::Mutation::Site->new(
        kind  => 'statement',
        text  => $text,
        start => $start,
        end   => $start + length $text,
        scope => [ 1, 1 ],
        %fields
    );
}

sub rules ( $file, %facts ) {
    return Test::Mutation::Mutant::Validity->new(
        text     => $file,
        heredocs => $facts{heredocs} || [],
        names    => $facts{names}    || { imports => [], declared => [] },
    );
}

sub refusal ( $file, $original, $replacement, %arg ) {
    my $start = index $file, $original;
    die "the text holds no $original\n" if $start < 0;
    my $facts = delete $arg{facts} || {};
    return rules( $file, %arg )->refusal( site( $original, $start, facts => $facts ), $replacement );
}

# The change of the text at one place of a file, named by what it leaves behind.
sub change ( $file, $start, $original, $replacement ) {
    die "the text holds no $original at $start\n" if substr( $file, $start, length $original ) ne $original;
    return rules($file)->change( site( $original, $start ), $replacement );
}

subtest 'the rules of a file refuse facts of another shape' => sub {
    like dies { Test::Mutation::Mutant::Validity->new( text => q{}, heredocs => [ [ 1, 2, 3 ] ], names => {} ) },
      qr/heredocs|names/, 'a here-document without its four offsets';
    like dies { rules(q{})->change( 'f', 'g' ) }, qr/Test::Mutation::Site/, 'a change of a text that is no site';
};

subtest 'two changes share a name exactly when they leave one text' => sub {
    my $file = "f(12) if !!\$x <= !\$y;\n";
    is change( $file, 0, 'f',     'f' ),     undef, 'a change that changes nothing has no name';
    is change( $file, 0, 'f(12)', 'f(12)' ), undef, 'however long its text is';

    my $plain = change( $file, 2, '12', '13' );
    ok defined $plain, 'a change that changes the text has one';
    is change( $file, 2, '12', '13' ), $plain, 'the same change again';
    isnt change( $file, 2, '12', '14' ), $plain, 'another text in that place';
    isnt change( $file, 2, '12', '21' ), change( $file, 2, '12', '11' ),
      'two texts of which one shares its end with the original';
    isnt change( $file, 2, '12', '2' ), change( $file, 2, '12', '1' ), 'two removals inside one span';

    is change( $file, 0,  'f(12)', 'f(13)' ), $plain, 'a wider span that changes the same character';
    is change( $file, 3,  '2',     '3' ),     $plain, 'and a narrower one';
    is change( $file, 14, '<=',    '>=' ),    change( $file, 14, '<', '>' ), 'a change that keeps the end of its span';

    is change( $file, 9, q{!}, q{} ),   change( $file, 10, q{!}, q{} ), 'the removal of either of two equal neighbors';
    isnt change( $file, 9, q{!}, q{} ), change( $file, 17, q{!}, q{} ), 'and the removal of a third one elsewhere';
    is change( $file, 9, q{!}, q{!!} ),   change( $file, 10, q{!}, q{!!} ), 'a copy written beside either of them';
    isnt change( $file, 9, q{!}, q{!!} ), change( $file, 9,  q{!}, q{} ),   'a copy written is no copy removed';

    my $pairs = 'xababy';
    is change( $pairs, 1, 'ab', q{} ),    change( $pairs, 3, 'ab', q{} ),  'the removal of either of two equal pairs';
    is change( $pairs, 1, 'ab', q{} ),    change( $pairs, 2, 'ba', q{} ),  'and of the pair that overlaps both';
    isnt change( $pairs, 1, 'ab', q{} ),  change( $pairs, 0, 'xa', q{} ),  'a removal that leaves another text';
    is change( 'xaby', 1, 'a', 'aba' ),   change( 'xaby', 2, 'b', 'bab' ), 'a pair written at either of two places';
    is change( 'xaby', 1, q{a}, 'aba' ),  change( 'xaby', 0, 'x', 'xab' ), 'and at a third one';
    isnt change( 'xaby', 1, 'a', 'aba' ), change( 'xaby', 1, 'a', 'aab' ), 'a pair written in another order';
    is change( 'xacy', 0, 'x', 'xab' ), change( 'xacy', 1, 'a', 'aba' ),
      'a text written before a copy of its start alone';
    is change( "x!!\ny",   1, q{!}, q{} ), change( "x!!\ny",   2, q{!}, q{} ), 'a removal before a line feed';
    is change( "a\n\n\nb", 1, "\n", q{} ), change( "a\n\n\nb", 3, "\n", q{} ), 'and the removal of a line feed itself';
};

subtest 'a change keeps the number of lines' => sub {
    is refusal( "f(1);\n",       'f(1);',       q{} ),       undef,        'a removed statement';
    is refusal( "f(1,\n  2);\n", "f(1,\n  2);", "\n" ),      undef,        'a removal that keeps the line feed';
    is refusal( "f(1,\n  2);\n", "f(1,\n  2);", q{} ),       'line-count', 'a removal that drops a line';
    is refusal( "f(1);\n",       'f(1);',       "g(1);\n" ), 'line-count', 'a change that adds a line';
};

subtest 'a change keeps a here-document whole or removes it whole' => sub {
    my $file = "sub f {\n    return <<\"T\" . g();\nline\nT\n}\n";

    # The introducer stands at 19 to 24, and its text stands at 32 to 39.
    my @heredocs = ( [ 19, 24, 32, 39 ] );
    my $refused  = sub ( $original, $replacement ) {
        return refusal( $file, $original, $replacement, heredocs => \@heredocs );
    };
    is substr( $file, 19, 5 ), '<<"T"',     'the fixture names the introducer';
    is substr( $file, 32, 7 ), "line\nT\n", 'and the text with its end';

    is $refused->( '<<"T" . g()', q{} ),    'here-document', 'a removed introducer leaves its text behind as code';
    is $refused->( '<<"T"',       q{'x'} ), 'here-document', 'and so does a replaced one';
    is $refused->( '"T" . g()',   q{} ),    'here-document', 'a change that cuts the introducer';
    is $refused->( "line\nT\n",   "\n\n" ), 'here-document', 'a removed text leaves its introducer behind';
    is $refused->( "ne\nT",       "\n" ),   'here-document', 'a change that cuts the text';

    is $refused->( "\n    return <<\"T\" . g();\nline\nT\n", "\n\n\n\n" ), undef,
      'a removed body takes the introducer and the text together';
    is $refused->( "<<\"T\" . g();\nline\nT\n", "1;\n\n\n" ), undef,
      'a change from the introducer to the end of the text';
    is $refused->( 'g()',      '1' ),        undef, 'a change beside the introducer';
    is $refused->( ' . g()',   q{} ),        undef, 'a change that starts where the introducer ends';
    is $refused->( 'return ',  'reTurn ' ),  undef, 'a change that ends where the introducer starts';
    is $refused->( ". g();\n", ". h();\n" ), undef, 'a change that ends where the text starts';
    is $refused->( '}',        q{ } ),       undef, 'a change that starts where the text ends';
    is $refused->( 'sub f {',  'sub g {' ),  undef, 'a change before the line of the introducer';

    is $refused->( '<<"T" . g()', '!(<<"T" . g())' ), undef,
      'a change that wraps the introducer keeps it on its line before its text';
    is $refused->( "<<\"T\" . g();\nline\nT\n", "!(<<\"T\") . g();\nline\nT\n" ), undef,
      'and so does one that keeps the text in its place';
    is $refused->( "<<\"T\" . g();\nline\nT\n", "!(<<\"T\") . g();\nT\nline\n" ), 'here-document',
      'a change that keeps the introducer and moves its text';
    is $refused->( '<<"T" . g()', 'g() . <<"T"' ),    undef,        'an introducer that moves along its line';
    is $refused->( '<<"T" . g()', "g() .\n<<\"T\"" ), 'line-count', 'and one that moves to another line adds one';
    is $refused->( '<<"T" . g()', '<<"T" . h()' ),    undef, 'a replacement can start with the complete introducer';
    is $refused->( '<<"T',        '<<T' ), 'here-document',  'a replacement cannot cut the end of an introducer';
    is $refused->( "<<\"T\" . g();\nli", "<<\"T\" . h();\nli" ), 'here-document',
      'a span containing the introducer cannot end inside the body';
    is $refused->( "<<\"T\" . g();\nline\nT\n}", "<<\"T\" . h();\nline\nT\n }" ), undef,
      'code following an intact body can change inside the replacement';

    my $swapped  = "my \$v = \$c\n  ? <<A\nbody\nA\n  : \$d;\n";
    my $branches = sub ( $original, $replacement ) {
        return refusal( $swapped, $original, $replacement, heredocs => [ [ 15, 18, 19, 26 ] ] );
    };
    is substr( $swapped, 15, 3 ), '<<A', 'a conditional with an introducer in its first branch';
    is $branches->( "<<A\nbody\nA\n  : \$d", "\$d\nbody\nA\n  : <<A" ), 'here-document',
      'a swap that moves the introducer below its text';

    my $pair = "f( \$c ? <<A : <<B );\na\nA\nb\nB\n";
    is refusal( $pair, '<<A : <<B', '<<B : <<A', heredocs => [ [ 8, 11, 21, 25 ], [ 14, 17, 25, 29 ] ] ),
      'here-document', 'a swap of two introducers on one line, which would swap their texts';
    my $both = "<<A, <<B;\na\nA\nb\nB\n";
    my @both = ( [ 0, 3, 10, 14 ], [ 5, 8, 14, 18 ] );
    is refusal( $both, '<<B', '0', heredocs => \@both ), 'here-document',
      'an unchanged document before a changed introducer does not end the check';
    is refusal( $both, $both, "1, <<B;\n\n\nx\nB\n", heredocs => \@both ), 'here-document',
      'removing one document still checks each later document';
    my $repeated = "<<X, <<X;\na\nX\nb\nX\n";
    is refusal( $repeated, $repeated, "<<X;\na\nX\nb\nX\n", heredocs => \@both ), 'here-document',
      'two documents cannot share the same introducer in the replacement';
};

subtest 'a change keeps what the rest of the file relies on' => sub {
    is refusal(
        "if ( open my \$h, '<', \$p ) { print \$h 1 }\n",
        q{open my $h, '<', $p},
        '1', facts => { declares => 1 }
      ),
      'declaration', 'a declaration that later code names';
    is refusal( "if ( open my \$h, '<', \$p ) { f() }\n", q{open my $h, '<', $p}, '1' ), undef,
      'a declaration that no later code names';
    is refusal(
        "if ( open my \$h, '<', \$p ) { print \$h 1 }\n",
        q{open my $h, '<', $p},
        q{!(open my $h, '<', $p)},
        facts => { declares => 1 }
      ),
      undef, 'a change that wraps the declaration keeps it';
    is refusal( 'my $answer = f()', 'my $answer = f()', 'my $answer = f() + 1', facts => { declares => 1 } ),
      undef, 'a replacement can start with the declaration that it keeps';
    is refusal( "package A;\n1;\n", '1', '0', facts => { final_value => 1 } ), 'final-value',
      'the true value that ends a module';
    is refusal( "package A;\nsub f { 1 }\n1;\n", '1', '0' ), undef, 'another number';
};

subtest 'a change that calls a function names one that the file resolves' => sub {
    my $resolved = sub ( $word, $target, %names ) {
        my @imports = map { { module => $_->[0], names => [ $_->@[ 1 .. $_->$#* ] ] } } @{ $names{imports} || [] };
        my $names   = { imports => \@imports, declared => $names{declared} || [] };
        return rules( q{}, names => $names )->resolved_call( $word, $target );
    };
    my @both = ( [ 'List::Util', 'any', 'all' ] );
    my @one  = ( [ 'List::Util', 'any' ] );

    is $resolved->( 'push', 'unshift' ), 'unshift', 'a core function replaces a core function';
    is $resolved->( 'lc', 'uc', declared => ['lc'] ), 'uc',
      'a subroutine of the file with the name of the original leaves the core function in place';
    is $resolved->( 'lc', 'uc', declared => ['uc'] ), 'CORE::uc',
      'a subroutine of the file with the other name would make the call ambiguous, so the core is named';
    is $resolved->( 'lc', 'uc', imports => [ [ 'My::Text', 'uc' ] ] ), 'CORE::uc',
      'and so would an import of the other name';
    is $resolved->( 'push', 'all' ), undef, 'a core function has no counterpart outside the core';
    is $resolved->( 'all', 'push' ), undef, 'and a name of unknown origin has none inside it';
    is $resolved->( 'max', 'min' ),  undef, 'a name of unknown origin';
    is $resolved->( 'max', 'min', declared => [ 'max', 'min' ] ), undef, 'a subroutine of the file';
    is $resolved->( q{%}, 'min' ),                                undef, 'a text that is no name';

    is $resolved->( 'any', 'all', imports => \@both ), 'all', 'a statement that imports both names';
    is $resolved->( 'any', 'all', imports => [ [ 'My::Tools', 'any', 'all' ] ] ), 'all',
      'whatever module they come from';
    is $resolved->( 'any', 'all', imports => \@one ), 'List::Util::all',
      'a statement that imports the original alone, so the module is named';
    is $resolved->( 'any', 'all', imports => [ @both, @one ] ), 'List::Util::all',
      'the other name is out of reach wherever one statement imports the original without it';
    is $resolved->( 'any', 'all', imports => [ @one, [ 'List::Util', 'all' ] ] ), 'List::Util::all',
      'and wherever another statement imports it';
    is $resolved->( 'any', 'all', imports => [ [ 'My::Tools', 'any' ] ] ), undef,
      'a module that is not known to provide the other name';
    is $resolved->( 'any', 'frobnicate', imports => \@one ), undef, 'a name that the module of the original lacks';
    is $resolved->( 'any', 'all', imports => [ [ 'My::Tools', 'any' ], [ 'List::MoreUtils', 'any' ], @one ] ),
      'List::MoreUtils::all', 'the first module that provides the other name';

    is $resolved->( 'List::Util::max',    'min' ),     'List::Util::min', 'a qualified call keeps its package';
    is $resolved->( 'My::Tools::max',     'min' ),     undef,             'a qualified call into an unknown package';
    is $resolved->( 'CORE::push',         'unshift' ), 'CORE::unshift',   'a core function under its qualified name';
    is $resolved->( 'CORE::GLOBAL::push', 'unshift' ), undef,             'another package of that kind';

    my @bundle = ( [ 'builtin', 'ceil', 'false', 'floor', 'true' ] );
    is $resolved->( 'ceil', 'floor', imports => [ [ 'POSIX', 'ceil', 'floor' ] ] ), 'floor', 'a default export';
    is $resolved->( 'ceil', 'floor', imports => [ @bundle, [ 'POSIX', 'ceil' ] ] ), 'builtin::floor',
      'two modules that provide the other name, of which the first is named';
    is $resolved->( 'true', 'false', imports => \@bundle ),                  'false', 'a boolean of the bundle';
    is $resolved->( 'true', 'false', imports => [ [ 'builtin', 'true' ] ] ), 'builtin::false', 'a boolean of the core';
    is $resolved->( 'true', 'false' ), undef, 'a bare word that only looks like a boolean';
};

done_testing;
