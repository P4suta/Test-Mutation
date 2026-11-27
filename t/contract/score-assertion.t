use v5.36;
use Test::Builder ();
use Test2::V0;
use File::Temp ();
use lib 't/contract/lib';
use Samples;
use Test::Mutation;

my $project = File::Temp::tempdir( CLEANUP => 1 );
my $other   = File::Temp::tempdir( CLEANUP => 1 );
my $sample  = Samples::result( statuses => ['Survived'] );

subtest 'the score assertion preserves a false-valued name and a zero threshold' => sub {
    my @seen;
    my @calls;
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub ( $config, $listener ) {
        push @calls, [ $config->root, $config->min_score ];
        $listener->( 'resolved', { inventory => 1 } );
        return $sample;
    };
    local $ENV{TEST_MUTATION_ROOT} = $other;
    my $answer;
    my $events = Test2::API::intercept {
        $answer = mutation_score_ok( root => $project, min => 0, name => '0', on_event => sub { push @seen, [@_] } );
    };
    is $answer, 1, 'zero permits a measured score of zero';
    is \@calls, [ [ $project, 0 ] ], 'the call measures the requested project with the supplied minimum';
    is \@seen,  [ [ 'resolved', { inventory => 1 } ] ], 'the caller receives the measurement event and payload';
    my @checks = grep { $_->isa('Test2::Event::Ok') } @$events;
    is scalar @checks,   1,   'the call emits one assertion';
    is $checks[0]->name, '0', 'the provided test name is preserved';
    my $unnamed = Test2::API::intercept { $answer = mutation_score_ok( root => $project ) };
    my ($failed) = grep { $_->isa('Test2::Event::Ok') } @$unnamed;
    is $answer,       0,                                     'the default minimum refuses a score of zero';
    is $failed->name, 'the mutation score is at least 100%', 'the default test name includes the minimum';
};

subtest 'the active project is identified by its resolved path' => sub {
    symlink $project, "$other/alias" or die "link to project: $!";
    local $ENV{TEST_MUTATION_ROOT} = "$other/alias";
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub { die "the assertion started a nested measurement\n" };
    my $answer;
    my $events = Test2::API::intercept { $answer = mutation_score_ok( root => $project ) };
    is $answer, 1, 'the skip returns true';
    my @checks = grep { $_->isa('Test2::Event::Skip') } @$events;
    is scalar @checks,     1,                       'the alias selects the active project';
    is $checks[0]->reason, 'inside a mutation run', 'the test explains the skip';
};

done_testing;
