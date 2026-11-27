use v5.36;
use Test2::V0;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Site;

# A mutator is a function of a site.
# Each one must read the kind and the role of the site, and never trust the text alone.

my %mutator = map { $_->name => $_ } Test::Mutation::Mutator::Catalog::mutators()->@*;

sub replacements ( $name, %site ) {
    my $site = Test::Mutation::Site->new( start => 0, end => length $site{text}, scope => [ 1, 1 ], %site );
    return [ map { $_->{replacement} } $mutator{$name}->mutations($site)->@* ];
}

my @accepted = (
    [ 'arithmetic',          { kind => 'operator', role => 'binary',   text => q{+} },      [q{-}] ],
    [ 'comparison-boundary', { kind => 'operator', role => 'binary',   text => 'lt' },      ['le'] ],
    [ 'comparison-negation', { kind => 'operator', role => 'binary',   text => q{==} },     ['!='] ],
    [ 'logical',             { kind => 'operator', role => 'binary',   text => q{&&} },     [q{||}] ],
    [ 'assignment',          { kind => 'operator', role => 'binary',   text => q{+=} },     [q{-=}] ],
    [ 'increment',           { kind => 'operator', role => 'update',   text => q{++} },     [q{--}] ],
    [ 'negation',            { kind => 'operator', role => 'unary',    text => q{!} },      [q{}] ],
    [ 'range-boundary',      { kind => 'operator', role => 'binary',   text => q{..} },     ['.. -1 +'] ],
    [ 'logical',             { kind => 'operator', role => 'binary',   text => 'xor' },     ['or'] ],
    [ 'logical',             { kind => 'operator', role => 'binary',   text => '^^' },      [q{||}] ],
    [ 'bitwise',             { kind => 'operator', role => 'binary',   text => q{&} },      [q{|}] ],
    [ 'bitwise',             { kind => 'operator', role => 'binary',   text => q{^.=} },    [q{&.=}] ],
    [ 'bitwise',             { kind => 'operator', role => 'unary',    text => q{~} },      [q{}] ],
    [ 'unary-minus',         { kind => 'operator', role => 'unary',    text => q{-} },      [q{}] ],
    [ 'predicate',           { kind => 'operator', role => 'unary',    text => '-e' },      ['!-e'] ],
    [ 'predicate',           { kind => 'word',     role => 'call',     text => 'defined' }, ['!defined'] ],
    [ 'condition-negation',  { kind => 'word',     role => 'compound', text => 'if' },      ['unless'] ],
    [ 'condition-negation',  { kind => 'word',     role => 'modifier', text => 'until' },   ['while'] ],
    [ 'loop-control',        { kind => 'word',     role => 'control',  text => 'last' },    ['next'] ],
    [ 'loop-control',        { kind => 'word',     role => 'control',  text => 'redo' },    ['next'] ],
    [ 'call-swap',           { kind => 'word',     role => 'call',     text => 'push' },    ['unshift'] ],
    [ 'boolean-literal',     { kind => 'word',     role => 'call',     text => 'true' },    ['false'] ],
    [ 'shift-pop',           { kind => 'word',     role => 'call',     text => 'shift' },   ['pop'] ],
    [ 'list-order',          { kind => 'word',     role => 'call',     text => 'sort' },    ['reverse sort'] ],
    [ 'call-removal', { kind => 'word', role => 'call', text => 'int', facts => { has_argument => 1 } }, [q{}] ],
    [ 'three-way',    { kind => 'comparison', text => '1 cmp 2', facts => { operands => [ 1, 6 ] } },    ['2 cmp 1'] ],
    [ 'early-exit',   { kind => 'guarded_exit', text => 'or return' },                                   [q{}] ],
    [ 'filter-negation',    { kind => 'filter', text => '$ok' },                                         ['!($ok)'] ],
    [ 'regex-class',        { kind => 'regex', role => 'class', text => '\D' },                          ['\d'] ],
    [ 'literal-collection', { kind => 'collection', text => '[2]' },                                     ['[]'] ],
    [ 'regex-anchor',       { kind => 'regex', role => 'anchor', text => q{^} },                         [q{}] ],
    [ 'regex-quantifier',   { kind => 'regex', role => 'quantifier', text => q{+} },                     [q{*}] ],
    [ 'regex-flag',         { kind => 'regex', role => 'flag', text => 'i' },                            [q{}] ],
    [ 'number-literal',     { kind => 'number', text => '41' },                                          ['42'] ],
    [ 'string-literal',     { kind => 'string', text => q{'abc'} },                                      [q{''}] ],
    [ 'statement-removal',  { kind => 'statement', text => 'f();', facts => { head => 'f' } },           [q{}] ],
    [ 'close-removal',      { kind => 'statement', text => 'close $h;', facts => { head => 'close' } },  [q{}] ],
    [ 'return-value',       { kind => 'return', text => '$x' },                                          [q{}] ],
    [ 'sub-body',           { kind => 'sub_body', text => ' f() ', facts => { name => 'g' } },           [q{}] ],
    [ 'condition-fixed',    { kind => 'condition', text => '$x', facts => { keyword => 'if' } },         [ '1', '0' ] ],
    [ 'condition-negation', { kind => 'condition', text => ' $x ', facts => { keyword => 'elsif' } },    ['!( $x )'] ],
    [
        'condition-negation', { kind => 'branches', text => "\$a . 1 :\n \$b", facts => { branches => [ 6, 10 ] } },
        ["\$b :\n \$a . 1"]
    ],
    [
        'condition-negation',
        { kind => 'branches', text => '$a = 1 : 2', facts => { branches => [ 6, 9 ], loose => 1 } },
        ['2 : ($a = 1)']
    ],
    [ 'unary-minus', { kind => 'number', text => '-0x1f' }, ['0x1f'] ],
    [ 'match', { kind => 'operator', role => 'binary', text => q{=~}, facts => { operand => 'match' } }, [q{!~}] ],
);

my %covered;
for my $case (@accepted) {
    my ( $name, $site, $expected ) = $case->@*;
    $covered{$name} = 1;
    my $shape = exists $site->{role} ? "$site->{kind} $site->{role}" : $site->{kind};
    is replacements( $name, $site->%* ), $expected, "$name changes $site->{text} as $shape";

    my ($other_kind) = grep { $_ ne $site->{kind} } qw(operator word);
    is replacements( $name, $site->%*, kind => $other_kind ), [],
      "$name leaves a $other_kind site with that text alone";
    next if !exists $site->{role};
    is replacements( $name, $site->%*, role => 'other' ), [], "$name leaves that text in another role alone";
}
is [ sort keys %covered ], [ sort keys %mutator ], 'every mutator of the catalog has a case';

is replacements( 'match', kind => 'operator', role => 'binary', text => q{=~}, facts => { operand => 'substitute' } ),
  [],
  'match leaves a substitution alone';
is replacements( 'match', kind => 'operator', role => 'binary', text => q{=~} ), [],
  'and an operand of an unknown class';
is replacements( 'string-literal', kind => 'string', text => q{'} ), [], 'string-literal leaves a lone quote alone';
is replacements( 'string-literal', kind => 'string', text => q{'a"} ), [],
  'and a string with a different closing quote';
is replacements( 'string-literal', kind => 'string', text => 'q{a}' ), ['q{}'], 'a quote operator keeps its delimiters';
is replacements( 'string-literal', kind => 'string', text => 'qq (b)' ), ['qq ()'],     'and the space before them';
is replacements( 'string-literal', kind => 'string', text => 'q!!' ),    ['q!mutant!'], 'and fills an empty one';
is replacements( 'string-literal', kind => 'string', text => 'qw(a)' ),  [],            'a list of words is no string';

my @refused = (
    [ 'bitwise',      { kind => 'operator', role => 'binary', text => q{&&} }, 'a logical and' ],
    [ 'bitwise',      { kind => 'operator', role => 'unary', text => q{-} },   'a sign' ],
    [ 'unary-minus',  { kind => 'operator', role => 'unary', text => q{+} },   'a unary plus' ],
    [ 'unary-minus',  { kind => 'number', text => '12' },                      'a number without a sign' ],
    [ 'logical',      { kind => 'operator', role => 'binary', text => q{^} },  'a bitwise exclusive or' ],
    [ 'loop-control', { kind => 'word', role => 'call', text => 'redo' },      'a redo that ends no statement' ],
    [ 'predicate',    { kind => 'word', role => 'call', text => 'ref' },       'a function that tests no state' ],
    [ 'predicate',    { kind => 'operator', role => 'unary', text => q{-} },   'a sign before its operand' ],
    [
        'condition-negation',
        { kind => 'condition', text => '$x', facts => { keyword => 'if' } },
        'the condition of an if'
    ],
    [ 'condition-negation', { kind => 'condition', text => '$x' },      'a condition without a keyword' ],
    [ 'condition-negation', { kind => 'branches',  text => '$a : $b' }, 'branches without their places' ],
    [ 'condition-negation', { kind => 'word', role => 'compound', text => 'for' }, 'a loop over a list' ],
);
is replacements( $_->[0], $_->[1]->%* ), [], "$_->[0] leaves $_->[2] alone" for @refused;
is [
    map { $_->{description} } $mutator{'condition-negation'}->mutations(
        Test::Mutation::Site->new(
            kind  => 'branches',
            text  => '$a : $b',
            start => 0,
            end   => 7,
            scope => [ 1, 1 ],
            facts => { branches => [ 2, 5 ] }
        )
    )->@*
  ],
  ['swapped the branches of the conditional'], 'the description of a swap';

done_testing;
