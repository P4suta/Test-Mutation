use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture statuses write_file);

my $root = copy_of('equivalent');

subtest 'a mutant that compiles to the code of the original is ignored' => sub {
    my ($result) = run_fixture($root);
    is statuses($result),
      {
        'lib/Fold.pm:6 removed the body of minute' => 'Killed',
        'lib/Fold.pm:6 removed the return value'   => 'Killed',
        'lib/Fold.pm:6 replaced + with -'          => 'Ignored',
        'lib/Fold.pm:8 removed the body of label'  => 'Killed',
        'lib/Fold.pm:10 removed the return value'  => 'Survived',
        'lib/Fold.pm:10 replaced if with unless'   => 'Survived',
        'lib/Fold.pm:10 removed !'                 => 'Ignored',
        'lib/Fold.pm:11 removed the return value'  => 'Killed',
      },
      'statuses';
    my %reason = map { $_->{mutant}->description => $_->{reason} } $result->entries->@*;
    is $reason{'replaced + with -'}, 'compiles to the same code as the original', 'the reason names the original';
    my ($kept) = grep { $_->{mutant}->description eq 'replaced if with unless' } $result->entries->@*;
    is $reason{'removed !'}, 'compiles to the same code as mutant ' . $kept->{mutant}->id,
      'a later mutant with the code of an earlier survivor names it';
    is $result->tally->{score}, 4 / 6 * 100, 'ignored mutants leave the score';
};

subtest 'a file that does not compile on its own keeps its survivors and warns' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$project/lib/Bound.pm",
        "package Bound;\nuse strict;\nuse warnings;\nBEGIN { die \"no application\\n\" if !\$main::APPLICATION }\nsub minute { return 60 + 0 }\n1;\n"
    );
    write_file( "$project/t/bound.t",
        "use Test::More tests => 1;\nBEGIN { \$main::APPLICATION = 1 }\nuse Bound;\nis Bound::minute(), 60, 'a minute';\n"
    );
    my ($result) = run_fixture($project);
    is statuses($result)->{'lib/Bound.pm:5 replaced + with -'}, 'Survived', 'the mutant survives';
    is [ grep { /compiled code/ } $result->warnings->@* ],
      ['lib/Bound.pm: B::Deparse gives no stable output, so the run compares no compiled code of the file'],
      'one warning names the file';
};

subtest 'the comparison can be turned off' => sub {
    my ($result) = run_fixture( $root, equivalence => 0 );
    my %statuses = statuses($result)->%*;
    is [ sort grep { $statuses{$_} eq 'Ignored' } keys %statuses ], [], 'no mutant is ignored';
    is scalar( grep { $_ eq 'Survived' } values %statuses ),        4,  'the four undetected mutants survive';
};

done_testing;
