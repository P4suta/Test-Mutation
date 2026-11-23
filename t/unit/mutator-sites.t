use v5.36;
use Test2::V0;
use Permutl::Mutator::Catalog;
use Permutl::Site;

# A mutator is a function of a site.
# Each one must read the kind and the role of the site, and never trust the text alone.

my %mutator = map { $_->name => $_ } Permutl::Mutator::Catalog::mutators()->@*;

sub replacements ( $name, %site ) {
    my $site = Permutl::Site->new( start => 0, end => length $site{text}, scope => [ 1, 1 ], %site );
    return [ map { $_->{replacement} } $mutator{$name}->mutations($site)->@* ];
}

my @accepted = (
    [ 'arithmetic',          { kind => 'operator', role => 'binary',     text => q{+} },    [q{-}] ],
    [ 'comparison',          { kind => 'operator', role => 'binary',     text => q{==} },   ['!='] ],
    [ 'string-comparison',   { kind => 'operator', role => 'binary',     text => 'eq' },    ['ne'] ],
    [ 'logical',             { kind => 'operator', role => 'binary',     text => q{&&} },   [q{||}] ],
    [ 'assignment',          { kind => 'operator', role => 'binary',     text => q{+=} },   [q{-=}] ],
    [ 'increment',           { kind => 'operator', role => 'update',     text => q{++} },   [q{--}] ],
    [ 'negation',            { kind => 'operator', role => 'unary',      text => q{!} },    [q{}] ],
    [ 'range-boundary',      { kind => 'operator', role => 'binary',     text => q{..} },   ['.. -1 +'] ],
    [ 'conditional-keyword', { kind => 'word',     role => 'compound',   text => 'if' },    ['unless'] ],
    [ 'conditional-keyword', { kind => 'word',     role => 'modifier',   text => 'if' },    ['unless'] ],
    [ 'loop-control',        { kind => 'word',     role => 'control',    text => 'last' },  ['next'] ],
    [ 'call-swap',           { kind => 'word',     role => 'call',       text => 'push' },  ['unshift'] ],
    [ 'boolean-literal',     { kind => 'word',     role => 'call',       text => 'true' },  ['false'] ],
    [ 'shift-pop',           { kind => 'word',     role => 'call',       text => 'shift' }, ['pop'] ],
    [ 'sort-order',          { kind => 'word',     role => 'call',       text => 'sort' },  ['reverse sort'] ],
    [ 'regex-anchor',        { kind => 'regex',    role => 'anchor',     text => q{^} },    [q{}] ],
    [ 'regex-quantifier',    { kind => 'regex',    role => 'quantifier', text => q{+} },    [q{*}] ],
    [ 'regex-flag',          { kind => 'regex',    role => 'flag',       text => 'i' },     [q{}] ],
    [ 'number-literal',      { kind => 'number', text => '41' },                                   ['42'] ],
    [ 'string-literal',      { kind => 'string', text => q{'abc'} },                               [q{''}] ],
    [ 'statement-removal',   { kind => 'statement', text => 'f();' },                              [q{}] ],
    [ 'return-value',        { kind => 'return', text => '$x' },                                   [q{}] ],
    [ 'sub-body',            { kind => 'sub_body', text => ' f() ', detail => { name => 'g' } },   [q{}] ],
    [ 'condition-fixed',     { kind => 'condition', text => '$x', detail => { keyword => 'if' } }, [ '1', '0' ] ],
    [ 'match', { kind => 'operator', role => 'binary', text => q{=~}, detail => { operand => 'match' } }, [q{!~}] ],
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

is replacements( 'match', kind => 'operator', role => 'binary', text => q{=~}, detail => { operand => 'substitute' } ),
  [],
  'match leaves a substitution alone';
is replacements( 'match', kind => 'operator', role => 'binary', text => q{=~} ), [],
  'and an operand of an unknown class';
is replacements( 'string-literal', kind => 'string', text => q{'} ), [], 'string-literal leaves a lone quote alone';
is replacements( 'string-literal', kind => 'string', text => q{'a"} ), [],
  'and a string with a different closing quote';
is replacements( 'string-literal', kind => 'string', text => 'q{a}' ), [], 'and a string in another quoting style';

done_testing;
