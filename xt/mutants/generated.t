use v5.36;
use Test2::V0;
use lib 't/lib';
use Gate;
use Matrix;
use Oracle;
use Snippets;
use Test::Mutation::Host;

# The whole product of the generator: every operator between every pair of operand shapes in every context.
# The fast gate reads the tuples that cover every pair of values, and this run reads every tuple.

my $workers = Test::Mutation::Host::processors()->{count};

subtest 'the walk rejects a snippet whose context loses the mutants of its expression' => sub {
    my %context  = map { $_->{name} => $_ } Snippets::contexts();
    my %operand  = map { $_->{name} => $_ } Snippets::operands();
    my $sum      = Snippets::expression( q{+}, @operand{ 'variable', 'literal' } );
    my @snippets = map { { context => $context{$_}, expression => $sum, shape => 'variable, literal' } } 'return',
      'final statement';
    my $summary = Snippets::surveyed( \@snippets, 1 );
    is $summary->{snippets}, { compiled => 2 }, 'perl compiles both snippets';
    is Oracle::found( $summary, 'context' ), [],
      'the return value keeps every change, and the final statement accounts for each one with a refusal';

    # The lists of a context that loses a change are written by hand, so the rejection depends on no blind spot of the tool.
    my @reference = ( '3 + -> - arithmetic', '5 2 -> 3 number-literal' );
    my @lost      = Snippets::difference( [], \@reference )->@*;
    is \@lost, [ '- 3 + -> - arithmetic', '- 5 2 -> 3 number-literal' ], 'a context without a change loses each one';
    is Gate::outcomes(
        sub {
            Gate::findings( 'mutants-context-rejected', [ map { "the context loses: $_" } @lost ] );
        }
      ),
      [ 'fail', 'pass' ], 'a finding outside the list fails the gate';
};

my @snippets = Snippets::chosen( Snippets::product( Snippets::sizes() ) );
my $summary  = Snippets::surveyed( \@snippets, $workers );

note $_ for Oracle::table( $summary->{tally}, Oracle::columns() ), Oracle::lines($summary), Oracle::rules($summary);
note "$_: $summary->{snippets}{$_}" for sort keys $summary->{snippets}->%*;
is $summary->{problems}, {}, 'the tool analyzes every snippet that perl compiles';
Gate::findings( "mutants-$_-product", Oracle::found( $summary, $_ ) ) for qw(a b b2 b3 d e context refusal);
my $total = Oracle::total( $summary->{tally} );
Gate::checked( 'snippets',                            scalar @snippets,               at_least => 40_000 );
Gate::checked( 'snippets that perl compiles',         $summary->{snippets}{compiled}, at_least => 30_000 );
Gate::checked( 'mutants that perl judged',            $total->{judged},               at_least => 80_000 );
Gate::checked( 'refused changes that perl judged',    $total->{asked},                at_least => 500 );
Gate::checked( 'verdicts that a cold perl confirmed', $summary->{crossed},            at_least => 5000 );

# Every operator between every pair of operand shapes runs as the value of a subroutine over the matrix.
my @expressions = Matrix::expressions( Snippets::product( ( Snippets::sizes() )[ 0 .. 2 ] ) );
my $matrix      = Matrix::surveyed( \@expressions, $workers, [ Matrix::rows() ] );
note $_ for Oracle::table( $matrix->{tally}, 'executed', 'inseparable:executed' ), Oracle::lines($matrix);
note "$_: $matrix->{expressions}{$_}" for sort keys $matrix->{expressions}->%*;
is $matrix->{problems}, {}, 'the tool analyzes every expression';
Gate::findings( 'mutants-c2-product', Oracle::found( $matrix, 'c2' ) );
Gate::checked( 'expressions',                      scalar @expressions,                           at_least => 2900 );
Gate::checked( 'expressions that perl runs',       $matrix->{expressions}{run},                   at_least => 2400 );
Gate::checked( 'mutants that ran over the matrix', Oracle::total( $matrix->{tally} )->{executed}, at_least => 4500 );

done_testing;
