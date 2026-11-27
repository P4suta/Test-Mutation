use v5.36;
use Test2::V0;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Site;
use Test::Mutation::Source;
use Test::Mutation::Syntax::PPI;
use lib 't/lib';
use Bounded;

my %mutator = map { $_->name => $_ } Test::Mutation::Mutator::Catalog::mutators()->@*;

sub replacements ( $name, $kind, $role, $text ) {
    my $site = Test::Mutation::Site->new(
        kind  => $kind,
        role  => $role,
        text  => $text,
        start => 0,
        end   => length($text),
        scope => [ 1, 1 ],
    );
    return [ map { $_->{replacement} } $mutator{$name}->mutations($site)->@* ];
}

sub sites ( $code, $kind ) {
    my $source = Test::Mutation::Source->new( path => 'Sample.pm', text => $code, encoding => 'UTF-8' );
    my ( $ended, $analysis ) = Bounded::ended( 2, sub { Test::Mutation::Syntax::PPI::analyze($source) } );
    die "analysis did not finish for $code\n" unless $ended;
    die $analysis->{problem} if defined $analysis->{problem};
    return grep { $_->kind eq $kind } $analysis->{sites}->@*;
}

sub spans ( $code, $kind ) {
    return [ map { [ $_->text, $_->role ] } sites( $code, $kind ) ];
}

is $mutator{arithmetic} ? replacements( 'arithmetic', 'operator', 'binary', '+' ) : [], ['-'],
  'the catalog constructs the binary addition mutator';
{
    my ( $text, $facts ) = ( \&Test::Mutation::Site::text, \&Test::Mutation::Site::facts );
    my @read;
    no warnings 'redefine';
    local *Test::Mutation::Site::text  = sub ($site) { push @read, 'text';  return $text->($site) };
    local *Test::Mutation::Site::facts = sub ($site) { push @read, 'facts'; return $facts->($site) };
    is replacements( 'arithmetic', 'operator', 'update', '++' ), [], 'an update has no arithmetic replacement';
    is \@read, [], 'rejecting an update needs neither the token text nor its operand facts';
    is replacements( 'arithmetic', 'operator', 'binary', 'xor' ), [], 'xor has no arithmetic replacement';
    is \@read, ['text'], 'an unlisted binary operator needs no operand facts';
}
is replacements( 'early-exit', 'guarded_exit', q{}, "or\nreturn" ),   ["\n"], 'removing an exit keeps line boundaries';
is replacements( 'number-literal', 'number',   q{}, '0.25' ),         ['1.25'], 'a decimal fraction advances by one';
is replacements( 'regex-flag',     'regex',    'modifier', '(?im:' ), [ '(?m:', '(?i:' ], 'each flag can be removed';
is replacements( 'regex-flag',     'word',     'flag',     'i' ),     [], 'a word cannot supply a pattern flag';
is warnings { is replacements( 'regex-flag', 'regex', 'modifier', 'i' ), [], 'a bare letter cannot open a modifier' },
  [], 'declining an incomplete modifier produces no warnings';
is replacements( 'literal-collection', 'collection', q{}, '[' ), [], 'a collection needs two delimiters';
my %active = map { $_->name => 1 } Test::Mutation::Mutator::Catalog::choose(
    profile => 'extended',
    enable  => [],
    disable => ['@regex']
)->@*;
is [ sort grep { !$active{$_} } keys %mutator ], [qw(regex-anchor regex-class regex-flag regex-quantifier)],
  'disabling the regex group removes exactly its four mutators';

my %nonliteral = map { $_->name => 1 } Test::Mutation::Mutator::Catalog::choose(
    profile => 'extended',
    enable  => [],
    disable => ['@literal']
)->@*;
is [ sort grep { !$nonliteral{$_} } keys %mutator ],
  [qw(boolean-literal literal-collection number-literal string-literal)],
  'the literal group includes collections, booleans, numbers, and strings';

is spans( 'm/>[a]$name.>[b][c]\h\d/gim;', 'regex' ),
  [ [ '[a]', 'class' ], [ '[b]', 'class' ], [ '[c]', 'class' ], [ '\d', 'class' ], [ 'i', 'flag' ], [ 'm', 'flag' ] ],
  'arrows need an interpolated variable and a dash, and flags after g keep their own positions';
is spans( 'm/\p{Alpha}[ab]\h[0-9]/;', 'regex' ), [ [ '[ab]', 'class' ], [ '[0-9]', 'class' ] ],
  'only supported complete character classes have spans';
is spans( 'm/$name->[0]/;', 'regex' ), [], 'an array index in an interpolation stays intact';
is spans( 's/a/b/gi;', 'regex' ), [ [ 'g', 'flag' ], [ 'i', 'flag' ] ], 'a substitution can remove its global flag';
is spans( q{open FH, '>', 'file'; foo(FH, '>', 'file');}, 'string' ),
  [ [ q{'>'}, 'open-mode' ], [ q{'file'}, q{} ], [ q{'>'}, q{} ], [ q{'file'}, q{} ] ],
  'only the mode argument of open has the special role';
is [ map { [ $_->text, $_->facts->{has_argument} ] } sites( 'int(); reverse; int $x; reverse @a; foo();', 'word' ) ],
  [ [ int => 0 ], [ reverse => 0 ], [ int => 1 ], [ reverse => 1 ], [ foo => undef ] ],
  'argument facts distinguish an explicit input and apply only to removable calls';
is spans( 'my @r = grep $_ > 1, @v;', 'filter' ), [ [ '$_ > 1', 'expression' ] ], 'the predicate stops at its comma';

for my $fragment ( 'grep', 'grep()', 'grep(;)', 'grep $_ > 1;', 'grep($_ > 1)' ) {
    is spans( $fragment, 'filter' ), [], "an incomplete grep has no predicate in $fragment";
}
is spans( '$a cmp ;',               'comparison' ),   [],                         'a comparison needs a right operand';
is spans( 'cmp $b;',                'comparison' ),   [],                         'a comparison needs a left operand';
is spans( 'sub f { $a cmp $b }',    'comparison' ),   [ [ '$a cmp $b', 'cmp' ] ], 'a comparison spans both operands';
is spans( 'sub f { $x || return }', 'guarded_exit' ), [ [ '|| return', q{} ] ], 'a guarded exit includes the transfer';
is warnings { is spans( '$x || ;', 'guarded_exit' ), [], 'a guard without a transfer is incomplete' },
  [], 'a missing transfer produces no warning';

my $location = \&PPI::Element::location;
for my $case (
    [ 'sub f { $left cmp $right }', 'comparison',   '$left' ],
    [ 'sub f { $left cmp $right }', 'comparison',   '$right' ],
    [ 'sub f { $x || return }',     'guarded_exit', 'return' ],
    [ 'my @a = grep $_ > 1, @v;',   'filter',       '1' ],
    [ 'my $a = [1, 2];',            'collection',   ']' ],
  )
{
    my ( $code, $kind, $misplaced ) = $case->@*;
    no warnings 'redefine';
    local *PPI::Element::location = sub ($token) {
        return $token->content eq $misplaced ? [ 1, 1, 1, 1, undef ] : $location->($token);
    };
    is spans( $code, $kind ), [], "a $kind with an unverified $misplaced span is dropped";
}

my $statement = \&PPI::Element::statement;
for my $case (
    [ 'PPI::Structure::Constructor', 'my $a = [1];',        'collection' ],
    [ 'PPI::Token::Regexp::Match',   'my $ok = /[ab]/i;',   'regex' ],
    [ 'PPI::Structure::Condition',   'if ($ok) { work() }', 'condition' ],
    [ 'PPI::Token::Operator',        'sub total { 1 + 2 }', 'operator' ],
  )
{
    my ( $class, $code, $kind ) = $case->@*;
    no warnings 'redefine';
    local *PPI::Element::statement = sub ($element) {
        return if $element->isa($class);
        return $statement->($element);
    };
    is spans( $code, $kind ), [], "a $kind without a running statement cannot supply coverage";
}
{
    no warnings 'redefine';
    local *PPI::Element::statement = sub ($element) {
        my $found = $statement->($element);
        return $element->isa('PPI::Token::Operator') && $element->content eq q{+} ? $found->clone : $found;
    };
    is [ map { $_->scope } grep { $_->text eq q{+} } sites( "my \$v = (\n2 +\n3\n);\n", 'operator' ) ],
      [ [ 2, 3 ] ], 'a detached expression keeps its own source lines as its coverage scope';
}

is spans( 'if ($ready', 'condition' ), [], 'an unterminated condition has no verified right delimiter';
{
    my $code  = 'if ($ready) { work() }';
    my $tree  = PPI::Document->new( \$code );
    my $start = \&PPI::Structure::start;
    no warnings 'redefine';
    local *PPI::Document::new    = sub { return $tree };
    local *PPI::Structure::start = sub ($structure) {
        return if $structure->isa('PPI::Structure::Condition');
        return $start->($structure);
    };
    is spans( $code, 'condition' ), [], 'a condition needs the opening delimiter from the parser';
}
for my $case (
    [ 'my $total = 2 + 3;', 'operator', 'my' ],
    [ 'my $total = 2 + 3;', 'operator', ';' ],
    [ 'sub measure { 3 }',  'sub_body', 'sub' ],
    [ 'sub measure { 3 }',  'sub_body', '}' ],
  )
{
    my ( $code, $kind, $missing ) = $case->@*;
    no warnings 'redefine';
    local *PPI::Element::location = sub ($token) {
        return if $token->content eq $missing;
        return $location->($token);
    };
    is spans( $code, $kind ), [], "the scope of a $kind needs the source line for its $missing token";
}
is spans( "sub measure { return \"a\r\nb\"; }\r\n", 'return' ), [],
  'a return value with unverified source bytes is left intact';
done_testing;
