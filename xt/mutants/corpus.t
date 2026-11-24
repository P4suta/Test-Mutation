use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use Gate;
use Library;
use Oracle;
use Test::Mutation::Project;

# The installed dependencies are a corpus of real code that nobody wrote with this tool in mind.
# Every mutant of every module has its text, its span, and its identity checked.
# Perl judges a sample: the same number of mutants of each mutator in each file, spread evenly over the file.

my $JUDGED  = 4;
my $PATCHED = 4;
my $PART    = 12_000;
my $workers = Test::Mutation::Project::cpu_count();

# A problem of the analysis is a defect of the tool, and a file that perl refuses as it stands is a fact of the corpus.
my %UNJUDGED = map { $_ => 1 } 'judge: perl refuses the original', 'judge: plain perl -c refuses the original',
  'judge: the modules that the judge holds change the original';

sub surveyed (@paths) {
    my $survey = sub ( $path, %task ) { return Oracle::survey( $path, %task, judged => $JUDGED, patched => $PATCHED ) };
    return Oracle::summary( Oracle::each_file( \@paths, $workers, $survey ) );
}

sub unanalyzed ($summary) {
    return [
        map { s/\Aanalysis: /the tool makes no mutant of a file: /r } grep { /\Aanalysis: / }
        sort keys $summary->{problems}->%*
    ];
}

sub judged_ok ( $scope, $summary ) {
    note $_ for Oracle::table( $summary->{tally}, Oracle::columns() ), Oracle::lines($summary);
    is [ grep { !/\Aanalysis: / && !$UNJUDGED{$_} } sort keys $summary->{problems}->%* ], [],
      "$scope: the judge answers for every file that perl compiles as it stands";
    Gate::findings( "mutants-files-$scope", unanalyzed($summary) );
    Gate::findings( "mutants-$_-$scope",    Oracle::found( $summary, $_ ) ) for qw(a b b2 d e literal);
    return Oracle::total( $summary->{tally} );
}

subtest 'the walk rejects a module with a mutant that perl refuses and one that calls nothing' => sub {
    my $directory = File::Temp->newdir;
    my %module    = (
        'Swap.pm'  => "use strict;\nuse List::Util qw(max);\nsub f { return max(\@_) }\nsub g { return max \@_ }\n1;\n",
        'Lines.pm' => "sub f { return 1 }\r\n1;\r\n",
        'Dies.pm'  => "use strict;\nBEGIN { die qq{never\\n} }\nsub f { return 1 }\n1;\n",
    );
    for my $name ( sort keys %module ) {
        open my $handle, '>:raw', "$directory/$name" or die "write $name: $!";
        print {$handle} $module{$name} or die "write $name: $!";
        close $handle                  or die "close $name: $!";
    }
    my $summary = surveyed( map { "$directory/$_" } sort keys %module );
    is Oracle::found( $summary, 'b' ),  ['call-swap yields code that perl refuses'], 'the swap without parentheses';
    is Oracle::found( $summary, 'b2' ), ['call-swap introduces an unresolved call'], 'the swap with parentheses';
    is unanalyzed($summary), ['the tool makes no mutant of a file: the file has carriage returns'],
      'the file that the tool leaves alone';
    is Gate::outcomes( sub { judged_ok( 'rejected', $summary ) } ),
      [ 'pass', 'fail', ('pass') x 3, 'fail', 'pass', 'fail', ('pass') x 7 ],
      'the three findings fail their gates, and the file that perl refuses as it stands fails nothing';
    is [ sort keys $summary->{problems}->%* ],
      [ 'analysis: the file has carriage returns', 'judge: perl refuses the original' ], 'the walk names both problems';
};

my @files   = Library::modules('local/lib/perl5')->@*;
my $summary = surveyed(@files);
my $total   = judged_ok( 'installed', $summary );
my $refused = scalar( ( $summary->{problems}{'judge: perl refuses the original'} || [] )->@* );
note sprintf '%d files, %d with sites, %d sites, %d that perl refuses as they stand', scalar @files,
  $summary->{files}, $summary->{sites}, $refused;

Gate::checked( 'installed modules',                   scalar @files,                at_least => 1200 );
Gate::checked( 'modules that the tool analyzed',      $summary->{files},            at_least => 1200 );
Gate::checked( 'modules that perl judged',            $summary->{files} - $refused, at_least => 1000 );
Gate::checked( 'mutants',                             $total->{mutants},            at_least => 600_000 );
Gate::checked( 'mutants that perl judged',            $total->{judged},             at_least => 35_000 );
Gate::checked( 'patches that were applied',           $total->{patched},            at_least => 35_000 );
Gate::checked( 'verdicts that a cold perl confirmed', $summary->{crossed},          at_least => 1000 );

# B::Deparse prints the compiled code of every mutant of the corpus, of the fixtures, and of the tool itself.
# A mutant with the code of its original is equivalent by construction, and the fast gate has no time for this print.
my @own      = map { Library::modules($_)->@* } 't/corpus', 't/fixtures', 'lib';
my $compared = Oracle::summary(
    Oracle::each_file(
        [ Oracle::in_parts( $PART, @own ) ],
        $workers,
        sub ( $path, %task ) {
            my ($root) = $path =~ m{\A(t/fixtures/[^/]+/lib|lib)/};
            return Oracle::survey( $path, %task, include => [ $root || () ], wants => [ 'calls', 'deparse' ] );
        }
    )
);
note $_ for Oracle::table( $compared->{tally}, Oracle::columns() ), Oracle::lines($compared);
is $compared->{problems}, {}, 'perl compiles every file of the corpus, of the fixtures, and of the tool as it stands';
Gate::findings( 'mutants-c-corpus', Oracle::found( $compared, 'c' ) );
Gate::checked(
    'mutants whose compiled code perl printed',
    Oracle::total( $compared->{tally} )->{compared},
    at_least => 4000
);

done_testing;
