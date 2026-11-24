use v5.36;
use Test2::V0;
use List::Util qw(max min sum0);
use lib 't/lib';
use Capability;
use Gate;
use Library;
use Oracle;
use Test::Mutation::Host;

# Every mutant of the corpus, of the fixtures, and of the tool itself stands before the oracles, with perl as the judge.
# A violation is a defect of the tool, and it stays in the open findings until the work that removes it.

my $OLDEST  = 36;
my $workers = min( 8, Test::Mutation::Host::processors()->{count} );

# The minor version of perl 5 that a file asks for in its first `use v5` line.
sub wanted_perl ($path) {
    my ($minor) = Oracle::file_source($path)->text =~ /^use v5[.](\d+)/m;
    return defined $minor ? $minor + 0 : $OLDEST;
}

# Perl judges and loads every mutant of the corpus and of the fixtures.
# The files of the tool get the oracles that read the text alone here, and the long run lets perl judge them.
sub surveyed (@paths) {
    return Oracle::summary(
        Oracle::each_file(
            \@paths,
            $workers,
            sub ($path) {
                my ($root) = $path =~ m{\A(t/fixtures/[^/]+/lib)/};
                return Oracle::survey( $path, judged => 0 ) if $path =~ m{\Alib/};
                return Oracle::survey( $path, include => [ $root || () ], wants => [ 'calls', 'load' ] );
            }
        )
    );
}

sub judged_ok ( $scope, $summary ) {
    note $_ for Oracle::table( $summary->{tally}, Oracle::columns() ), Oracle::lines($summary), Oracle::rules($summary);
    is $summary->{problems}, {}, "$scope: the tool analyzes every file, and perl compiles each as it stands";
    Gate::findings( "mutants-$_-$scope", Oracle::found( $summary, $_ ) ) for qw(a b b2 b3 d e literal refusal);
    my $refusals = sum0 map { values $_->%* } values $summary->{refusals}->%*;
    return { Oracle::total( $summary->{tally} )->%*, crossed => $summary->{crossed}, refusals => $refusals };
}

subtest 'the walk rejects a file that perl refuses as it stands' => sub {
    my $summary = Oracle::summary( [ [ 'lib/A.pm', 'problem', 'judge', 'perl refuses the original' ] ] );
    is Gate::outcomes( sub { judged_ok( 'rejected', $summary ) } ), [ 'fail', ('pass') x 16 ],
      'a problem fails the walk, and the oracles find nothing in it';
};

subtest 'the walk rejects no file for the perl that it asks for' => sub {
    is wanted_perl('t/corpus/modern/Heredoc.pm'), 36, 'a file for the oldest perl of the hosted jobs';
    is wanted_perl('t/corpus/modern/Class.pm'),   38, 'a file with the class syntax';
    is wanted_perl('lib/Test/Mutation/Shim.pm'),  36, 'a file without a version line runs on every perl';
};

# A file that asks for a newer perl than the oldest one of the hosted jobs stands apart, under a capability.
my @files  = map  { Library::modules($_)->@* } 't/corpus', 't/fixtures', 'lib';
my %wanted = map  { $_ => wanted_perl($_) } @files;
my @modern = grep { $wanted{$_} > $OLDEST } @files;
my $newest = max( $OLDEST, @wanted{@modern} );
my $total  = judged_ok( 'corpus', surveyed( grep { $wanted{$_} <= $OLDEST } @files ) );
Gate::checked( 'files',                               scalar @files,      at_least => 50 );
Gate::checked( 'mutants',                             $total->{mutants},  at_least => 4500 );
Gate::checked( 'mutants that perl judged',            $total->{judged},   at_least => 200 );
Gate::checked( 'patches that were applied',           $total->{patched},  at_least => 4500 );
Gate::checked( 'mutants that perl loaded',            $total->{loaded},   at_least => 190 );
Gate::checked( 'verdicts that a cold perl confirmed', $total->{crossed},  at_least => 25 );
Gate::checked( 'changes that the tool refused',       $total->{refusals}, at_least => 140 );

# The class syntax needs Perl 5.38, and one file of the corpus asks for Perl 5.40.
Gate::checked( 'files for a newer perl', scalar @modern, at_least => 3 );
my $needed = sprintf '5.%03d', $newest;
if ( Capability::has( 'class', $] >= $needed, "some files of the corpus and of the fixtures need Perl 5.$newest" ) ) {
    my $modern = judged_ok( 'modern', surveyed(@modern) );
    Gate::checked( 'mutants of the modern files that perl judged', $modern->{judged}, at_least => 40 );
}

done_testing;
