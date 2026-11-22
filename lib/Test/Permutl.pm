package Test::Permutl;
use v5.36;
use Exporter        qw(import);
use Test::Builder   ();
use Types::Standard qw(Bool HashRef Slurpy);
use Type::Params    qw(signature_for);
use Permutl;
use Permutl::Report::Terminal;

our $VERSION = '0.001';
our @EXPORT  = qw(mutation_score_ok);    ## no critic (Modules::ProhibitAutomaticExportation)

signature_for mutation_score_ok => ( positional => [ Slurpy [HashRef] ], returns => Bool );

sub mutation_score_ok ($settings) {
    my %settings = ( root => q{.}, $settings->%* );
    my $minimum  = exists $settings{min}  ? delete $settings{min}  : 100;
    my $name     = exists $settings{name} ? delete $settings{name} : "the mutation score is at least $minimum%";

    my $result  = Permutl::run(%settings);
    my $score   = $result->tally->{score};
    my $reached = $result->conclusive && defined $score && $score >= $minimum ? 1 : 0;

    my $builder = Test::Builder->new;
    $builder->ok( $reached, $name );
    $builder->diag( Permutl::Report::Terminal::render( $result, color => 0 ) ) if !$reached;
    return $reached;
}

1;

__END__

=head1 NAME

Test::Permutl - assert a mutation score in a test file

=head1 SYNOPSIS

    use Test::More tests => 1;
    use Test::Permutl;

    mutation_score_ok( min => 80 );

=head1 DESCRIPTION

The module runs permutl on the project in the current directory from an author test.
A test file under C<xt/> keeps the measurement out of the tests that permutl itself runs.

=head1 FUNCTIONS

=head2 mutation_score_ok

    mutation_score_ok( min => 80, name => 'tests detect mutants', jobs => 4, profile => 'extended' );

Passes when the run is conclusive and the score reaches C<min>, 100 by default.
C<name> names the test, and every other setting goes to L<Permutl/run>.
A failing assertion prints the report with the undetected mutants as diagnostics.

=cut
