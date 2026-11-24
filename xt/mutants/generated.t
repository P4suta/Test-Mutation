use v5.36;
use Test2::V0;
use lib 't/lib';
use Gate;
use Oracle;
use Snippets;
use Test::Mutation::Project;

# The whole product of the generator: every operator between every pair of operand shapes in every context.
# The fast gate reads the tuples that cover every pair of values, and this run reads every tuple.

my $workers = Test::Mutation::Project::cpu_count();

subtest 'the walk rejects a snippet whose context loses the mutants of its expression' => sub {
    my %context  = map { $_->{name} => $_ } Snippets::contexts();
    my %operand  = map { $_->{name} => $_ } Snippets::operands();
    my $sum      = Snippets::expression( q{+}, @operand{ 'variable', 'literal' } );
    my @snippets = map { { context => $context{$_}, expression => $sum, shape => 'variable, literal' } } 'return',
      'use statement';
    my $summary = Snippets::surveyed( \@snippets, 1 );
    is $summary->{snippets}, { compiled => 2 }, 'perl compiles both snippets';
    is Oracle::found( $summary, 'context' ), ['the context changes the mutants of an expression: use statement'],
      'the expression has no mutant in the use statement, and the return value keeps every one';
    is Gate::outcomes( sub { Gate::findings( 'mutants-context-rejected', Oracle::found( $summary, 'context' ) ) } ),
      [ 'fail', 'pass' ], 'a finding outside the list fails the gate';
};

my @snippets = Snippets::chosen( Snippets::product( Snippets::sizes() ) );
my $summary  = Snippets::surveyed( \@snippets, $workers );

note $_ for Oracle::table( $summary->{tally}, Oracle::columns() ), Oracle::lines($summary);
note "$_: $summary->{snippets}{$_}" for sort keys $summary->{snippets}->%*;
is $summary->{problems}, {}, 'the tool analyzes every snippet that perl compiles';
Gate::findings( "mutants-$_-product", Oracle::found( $summary, $_ ) ) for qw(a b b2 b3 d e context);
my $total = Oracle::total( $summary->{tally} );
Gate::checked( 'snippets',                            scalar @snippets,               at_least => 40_000 );
Gate::checked( 'snippets that perl compiles',         $summary->{snippets}{compiled}, at_least => 30_000 );
Gate::checked( 'mutants that perl judged',            $total->{judged},               at_least => 150_000 );
Gate::checked( 'verdicts that a cold perl confirmed', $summary->{crossed},            at_least => 10_000 );

done_testing;
