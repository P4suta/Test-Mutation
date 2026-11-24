use v5.36;
use Test2::V0;
use List::Util qw(min sum0);
use lib 't/lib';
use Gate;
use Oracle;
use Snippets;
use Test::Mutation::Project;

# Generated snippets put every operator of PPI between operands of every shape, in every context that runs code.
# The list has no random part, and perl decides which snippets are code at all.
# Each snippet goes through the oracles, and its expression must have the same mutants in every context.

subtest 'the pairs reject a tuple list that leaves a pair out' => sub {
    my @sizes  = ( 5, 3, 4, 2 );
    my @tuples = Snippets::pairwise(@sizes);
    my %pair;
    for my $tuple (@tuples) {
        for my $one ( 0 .. $#sizes ) {
            $pair{"$one=$tuple->[$one] $_=$tuple->[$_]"} = 1 for $one + 1 .. $#sizes;
        }
    }
    my $wanted = 5 * 3 + 5 * 4 + 5 * 2 + 3 * 4 + 3 * 2 + 4 * 2;
    is scalar( keys %pair ), $wanted, 'every value of an axis meets every value of every other axis';
    ok @tuples >= 20 && @tuples <= 30, 'in about as many tuples as the two largest axes need (' . @tuples . ')';
    is [ Snippets::pairwise(@sizes) ], \@tuples, 'the list is the same in every run';
    is scalar(
        grep {
            $_->@* != 4
              || grep { !defined }
              $_->@*
        } @tuples
      ),
      0, 'every tuple names a value of every axis';
    is scalar( Snippets::product(@sizes) ), 5 * 3 * 4 * 2, 'the product holds every tuple';
};

subtest 'the generator takes its operators from the table of PPI' => sub {
    my %operator = map { $_ => 1 } Snippets::operators();
    ok $operator{$_},    "the binary operator $_" for qw(+ ** <=> cmp x .. && // and xor |. **= //= ^.=);
    ok !$operator{$_},   "no binary operator $_"  for qw(-> ++ ! ~ ? : => <> not), q{,};
    ok !$operator{'~~'}, 'no smartmatch, which perl 5.42 removed';
    is [ grep { !$PPI::Singletons::OPERATOR{$_} } keys %operator ], [], 'and no operator from elsewhere';
};

subtest 'a snippet file places each expression and the text of its here-document' => sub {
    my %context = map { $_->{name} => $_ } Snippets::contexts();
    my %operand = map { $_->{name} => $_ } Snippets::operands();
    my $plain   = Snippets::expression( q{+}, @operand{ 'variable',      'literal' } );
    my $heredoc = Snippets::expression( q{.}, @operand{ 'here-document', 'call' } );
    is $plain->{text},   '$x + 2',           'an operator between two operands';
    is $heredoc->{text}, q{<<'EOT' . f($y)}, 'an operand that is a here-document';

    my $file = Snippets::file( $context{'return'}, $plain, $heredoc );
    is $file->{text}, <<'CODE', 'one package for each expression, and the text of a here-document after its line';
use v5.36;
no warnings;
package Snippet::N0;
our ( $x, $y, $r );
BEGIN { ( $x, $y, $r ) = ( 3, 4, { k => 5, list => [ 1, 2 ] } ) }
sub f { return $_[0] }
sub c { return $x + 2 }
package Snippet::N1;
our ( $x, $y, $r );
BEGIN { ( $x, $y, $r ) = ( 3, 4, { k => 5, list => [ 1, 2 ] } ) }
sub f { return $_[0] }
sub c { return <<'EOT' . f($y) }
7
EOT
1;
CODE
    is [ map { substr $file->{text}, $_->[0], $_->[1] - $_->[0] } $file->{spans}->@* ],
      [ '$x + 2', q{<<'EOT' . f($y)} ], 'each span addresses its expression';

    my $source  = Oracle::text_source( 'lib/Snippet.pm', $file->{text} );
    my $changes = Oracle::candidates( $source, Oracle::generated($source) );
    is [ Snippets::inside( $changes, $file->{spans}[0] ) ], [ '3 + -> - arithmetic', '5 2 -> 3 number-literal' ],
      'the changes inside an expression, by their place in it';
    is [ Snippets::inside( $changes, [ 0, 5 ] ) ], [], 'and none outside it';
};

subtest 'the context check rejects a context that changes the mutants of an expression' => sub {
    my %context = map { $_->{name} => $_ } Snippets::contexts();
    my %operand = map { $_->{name} => $_ } Snippets::operands();
    my $sum     = Snippets::expression( q{+}, @operand{ 'variable', 'literal' } );
    is Snippets::lost( $context{'assignment'},      $sum ), [], 'the reference context loses nothing';
    is Snippets::lost( $context{'return'},          $sum ), [], 'and neither does a return value';
    is Snippets::lost( $context{'final statement'}, $sum ), [],
      'a context whose changes the generator refuses with a rule accounts for each of them';

    # The lists of a context that loses and adds a change are written by hand, as no context of the tool has to do it.
    my @reference = ( '3 + -> - arithmetic', '5 2 -> 3 number-literal' );
    is Snippets::difference( ['3 + -> - arithmetic'], \@reference ), ['- 5 2 -> 3 number-literal'],
      'a context without one change of the reference loses it';
    is Snippets::difference( [ @reference, '1  $x  -> 1 condition-fixed' ], \@reference ),
      ['+ 1  $x  -> 1 condition-fixed'], 'and a context with a change of its own adds it';
    is Snippets::difference( [], \@reference ), [ '- 3 + -> - arithmetic', '- 5 2 -> 3 number-literal' ],
      'a context that the analysis never reads loses every change';
};

# Perl compiles each snippet alone first, so a combination that is no code leaves the list.
my @snippets = Snippets::chosen( Snippets::pairwise( Snippets::sizes() ) );
my $workers  = min( 8, Test::Mutation::Project::cpu_count() );
my $summary  = Snippets::surveyed( \@snippets, $workers );

note $_ for Oracle::table( $summary->{tally}, Oracle::columns() ), Oracle::lines($summary), Oracle::rules($summary);
note "$_: $summary->{snippets}{$_}" for sort keys $summary->{snippets}->%*;
is $summary->{problems}, {}, 'the tool analyzes every snippet that perl compiles';
Gate::findings( "mutants-$_-generated", Oracle::found( $summary, $_ ) ) for qw(a b b2 b3 d e context refusal);
my $total = Oracle::total( $summary->{tally} );
Gate::checked( 'snippets',                            scalar @snippets,               at_least => 800 );
Gate::checked( 'snippets that perl compiles',         $summary->{snippets}{compiled}, at_least => 600 );
Gate::checked( 'mutants',                             $total->{mutants},              at_least => 3000 );
Gate::checked( 'mutants that perl judged',            $total->{judged},               at_least => 2000 );
Gate::checked( 'verdicts that a cold perl confirmed', $summary->{crossed},            at_least => 140 );
Gate::checked(
    'changes that the tool refused',
    sum0( map { values $_->%* } values $summary->{refusals}->%* ),
    at_least => 1400
);
Gate::checked( 'refused changes that perl judged', $total->{asked}, at_least => 15 );

done_testing;
