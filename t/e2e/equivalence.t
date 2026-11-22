use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture statuses);

my $root = copy_of('equivalent');

subtest 'a mutant that compiles to the code of the original is ignored' => sub {
    my ($result) = run_fixture($root);
    is statuses($result),
      {
        'lib/Fold.pm:5 removed the body of minute' => 'Killed',
        'lib/Fold.pm:5 removed the return value'   => 'Killed',
        'lib/Fold.pm:5 replaced + with -'          => 'Ignored',
        'lib/Fold.pm:7 removed the body of label'  => 'Killed',
        'lib/Fold.pm:9 removed the return value'   => 'Survived',
        'lib/Fold.pm:9 replaced if with unless'    => 'Survived',
        'lib/Fold.pm:9 removed !'                  => 'Ignored',
        'lib/Fold.pm:10 removed the return value'  => 'Killed',
      },
      'statuses';
    my %reason = map { $_->{mutant}->description => $_->{reason} } $result->entries->@*;
    is $reason{'replaced + with -'}, 'compiles to the same code as the original', 'the reason names the original';
    my ($kept) = grep { $_->{mutant}->description eq 'replaced if with unless' } $result->entries->@*;
    is $reason{'removed !'}, 'compiles to the same code as mutant ' . $kept->{mutant}->id,
      'a later mutant with the code of an earlier survivor names it';
    is $result->tally->{score}, 4 / 6 * 100, 'ignored mutants leave the score';
};

subtest 'the comparison can be turned off' => sub {
    my ($result) = run_fixture( $root, equivalence => 0 );
    my %statuses = statuses($result)->%*;
    is [ sort grep { $statuses{$_} eq 'Ignored' } keys %statuses ], [], 'no mutant is ignored';
    is scalar( grep { $_ eq 'Survived' } values %statuses ),        4,  'the four undetected mutants survive';
};

done_testing;
