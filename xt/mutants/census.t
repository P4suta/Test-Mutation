use v5.36;
use Test2::V0;
use List::Util qw(sum0);
use lib 't/lib';
use Census;
use Gate;
use Library;
use Oracle;
use Test::Mutation::Project;

# The census of every installed module.
# The fast gate holds the keys that the corpus, the fixtures, and the tool itself show, and this run adds the keys of real code.

my $workers = Test::Mutation::Project::cpu_count();

sub census_of (@paths) {
    return Census::summary(
        Oracle::each_file( \@paths, $workers, sub ($path) { return Census::records( Oracle::file_source($path) ) } ) );
}

subtest 'the census rejects a construct of real code that the fast gate never reads' => sub {
    my %near = ( observed => { 'operator +' => 9, 'word elsif' => 2 }, claimed => { 'operator +' => 9 } );
    my %far  = ( observed => { 'operator +' => 5, 'word elsif' => 4, 'word wantarray' => 1 }, claimed => {} );
    is Census::beyond( \%far, \%near ),
      { observed => { 'word wantarray' => 1 }, claimed => {}, statements => {}, files => {}, unplaced => 0 },
      'a key of the far corpus alone stays, and a key that both show belongs to the near one';
    is Census::undecided( Census::beyond( \%far, \%near ), {} ),
      ['no mutant covers word wantarray, and no reason declines it'], 'and it is a finding of its own';
};

my @files = Library::modules('local/lib/perl5')->@*;
my $near  = census_of( map { Library::modules($_)->@* } 't/corpus', 't/fixtures', 'lib' );
my $far   = census_of(@files);

note sprintf '%-28s %8d observed, %8d claimed', $_, $far->{observed}{$_}, $far->{claimed}{$_} || 0
  for sort keys $far->{observed}->%*;
note sprintf '%-28s %7d statements, %7d without a mutant', $_, $far->{statements}{$_}->@{qw(all bare)}
  for sort keys $far->{statements}->%*;
note sprintf '%s: %d of %d statements without a mutant', $_->@* for Census::barest_files( $far, 20 );
note "$far->{unplaced} tokens stand where PPI does not place them, and the analysis drops each without a count";

# A key that the fast gate decides has its finding there, so this gate holds the keys of the installed modules alone.
# The fast gate shows every declined construct in a seed text, and here a reason counts for the keys that this corpus adds.
my $added    = Census::beyond( $far, $near );
my $declined = Census::declined();
my %reason   = map { $_ => $declined->{$_} } grep { $added->{observed}{$_} } keys $declined->%*;
Gate::findings( 'mutants-census-installed', Census::undecided( $added, \%reason ) );
Gate::findings( 'mutants-statements-installed',
    [ map { "no mutant touches a statement of the class $_" } Census::bare_classes($far)->@* ] );
Gate::findings( 'mutants-dropped-installed',
    [ $far->{unplaced} ? 'the analysis drops a token that PPI places on another text, without a count' : () ] );
Gate::checked( 'files',      scalar @files,                                           at_least => 1200 );
Gate::checked( 'keys',       scalar keys $far->{observed}->%*,                        at_least => 200 );
Gate::checked( 'tokens',     sum0( values $far->{observed}->%* ),                     at_least => 2_000_000 );
Gate::checked( 'statements', sum0( map { $_->{all} } values $far->{statements}->%* ), at_least => 250_000 );

done_testing;
