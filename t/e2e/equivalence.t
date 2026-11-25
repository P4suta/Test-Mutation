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
        'lib/Fold.pm:6 removed the body of size'                => 'Killed',
        'lib/Fold.pm:6 removed the return value'                => 'Killed',
        'lib/Fold.pm:6 replaced > with <='                      => 'Killed',
        'lib/Fold.pm:6 replaced > with >='                      => 'Ignored',
        'lib/Fold.pm:6 swapped the branches of the conditional' => 'Killed',
        'lib/Fold.pm:8 removed the body of label'               => 'Killed',
        'lib/Fold.pm:10 removed the return value'               => 'Survived',
        'lib/Fold.pm:10 replaced if with unless'                => 'Survived',
        'lib/Fold.pm:10 removed !'                              => 'Ignored',
        'lib/Fold.pm:11 removed the return value'               => 'Killed',
      },
      'statuses';
    my %reason = map { $_->{mutant}->description => [ $_->@{qw(reason detail)} ] } $result->entries->@*;
    is $reason{'replaced > with >='}, [ 'same-code-as-original', 'compiles to the same code as the original' ],
      'the reason names the original';
    my ($kept) = grep { $_->{mutant}->description eq 'replaced if with unless' } $result->entries->@*;
    is $reason{'removed !'}, [ 'same-code-as-mutant', 'compiles to the same code as mutant ' . $kept->{mutant}->id ],
      'a later mutant with the code of an earlier survivor names it';
    is $result->tally->{score}, 6 / 8 * 100, 'ignored mutants leave the score';
};

subtest 'a file that does not compile on its own keeps its survivors and warns' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$project/lib/Bound.pm",
        "package Bound;\nuse strict;\nuse warnings;\nBEGIN { die \"no application\\n\" if !\$main::APPLICATION }\nsub size { return 10 > 5 ? 'big' : 'small' }\n1;\n"
    );
    write_file( "$project/t/bound.t",
        "use Test::More tests => 1;\nBEGIN { \$main::APPLICATION = 1 }\nuse Bound;\nis Bound::size(), 'big', 'a size';\n"
    );
    my ($result) = run_fixture( $project, enable => ['comparison-boundary'] );
    is statuses($result)->{'lib/Bound.pm:5 replaced > with >='}, 'Survived', 'the mutant survives';
    is [ grep { /compiled code/ } $result->warnings->@* ],
      ['lib/Bound.pm: Perl decompiles the file to no stable text, so the run compares no compiled code of the file'],
      'one warning names the file';
};

subtest 'a mutant that no test reaches is compared too' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file(
        "$project/lib/Idle.pm",
        join "\n",
        'package Idle;',
        'use strict;',
        'use warnings;',
        q{sub size { return 10 > 5 ? 'big' : 'small' }},
        'sub hour { return 60 * 60 }',
        'sub used { return $_[0] }',
        'sub label {',
        q{    return 'none' if !$_[0];},
        q{    return 'some';},
        '}',
        'sub other {',
        q{    return 'zero' if !$_[1];},
        q{    return 'more';},
        '}',
        '1;',
        q{},
    );
    write_file( "$project/t/idle.t", "use Test::More tests => 1;\nuse Idle;\nis Idle::used(7), 7, 'used';\n" );
    my ($result) = run_fixture( $project, enable => ['comparison-boundary'] );
    is statuses($result),
      {
        'lib/Idle.pm:4 removed the body of size'                => 'NoCoverage',
        'lib/Idle.pm:4 removed the return value'                => 'NoCoverage',
        'lib/Idle.pm:4 replaced > with <='                      => 'NoCoverage',
        'lib/Idle.pm:4 replaced > with >='                      => 'Ignored',
        'lib/Idle.pm:4 swapped the branches of the conditional' => 'Ignored',
        'lib/Idle.pm:5 removed the body of hour'                => 'NoCoverage',
        'lib/Idle.pm:5 removed the return value'                => 'NoCoverage',
        'lib/Idle.pm:5 replaced * with /'                       => 'NoCoverage',
        'lib/Idle.pm:6 removed the body of used'                => 'Killed',
        'lib/Idle.pm:6 removed the return value'                => 'Killed',
        'lib/Idle.pm:7 removed the body of label'               => 'NoCoverage',
        'lib/Idle.pm:8 removed the return value'                => 'NoCoverage',
        'lib/Idle.pm:8 replaced if with unless'                 => 'NoCoverage',
        'lib/Idle.pm:8 removed !'                               => 'Ignored',
        'lib/Idle.pm:9 removed the return value'                => 'NoCoverage',
        'lib/Idle.pm:11 removed the body of other'              => 'NoCoverage',
        'lib/Idle.pm:12 removed the return value'               => 'NoCoverage',
        'lib/Idle.pm:12 replaced if with unless'                => 'NoCoverage',
        'lib/Idle.pm:12 removed !'                              => 'Ignored',
        'lib/Idle.pm:13 removed the return value'               => 'NoCoverage',
      },
      'a change without effect leaves the score, and a real change stays uncovered';
    for my $line ( 8, 12 ) {
        my %entry =
          map { $_->{mutant}->description => $_ } grep { $_->{mutant}->from->[0] == $line } $result->entries->@*;
        is $entry{'removed !'}{detail},
          'compiles to the same code as mutant ' . $entry{'replaced if with unless'}{mutant}->id,
          "the repeated change on line $line names the mutant that stays";
    }
    is $result->tally->{score}, 2 / 16 * 100, 'the four ignored mutants leave the score';
};

subtest 'the comparison can be turned off' => sub {
    my ($result) = run_fixture( $root, equivalence => 0 );
    my %statuses = statuses($result)->%*;
    is [ sort grep { $statuses{$_} eq 'Ignored' } keys %statuses ], [], 'no mutant is ignored';
    is scalar( grep { $_ eq 'Survived' } values %statuses ),        4,  'the four undetected mutants survive';
};

done_testing;
