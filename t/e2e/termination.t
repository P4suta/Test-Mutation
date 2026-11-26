use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Bounded;
use Fixture qw(run_fixture write_file);
use Test::Mutation::Pool;
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
write_file( "$root/lib/Arithmetic.pm", <<'MODULE' );
package Arithmetic;
sub checked { return $_[0] + $_[1] }
sub sampled { return $_[0] + $_[1] }
sub unused  { return $_[0] + $_[1] }
1;
MODULE
write_file( "$root/t/arithmetic.t", <<'TEST' );
use Test::More tests => 2;
use Arithmetic;
is Arithmetic::checked(2, 3), 5;
is Arithmetic::sampled(2, 0), 2;
TEST

my $config = Test::Mutation::Settings::of_call( { root => $root, cache => 0 } );
my $chosen = Test::Mutation::Select::resolve( config => $config );
my @ids    = map { $_->id } grep { $_->mutator eq 'arithmetic' } $chosen->mutants->@*;
is scalar @ids, 3, 'each addition supplies one change';

my $pool   = Test::Mutation::Pool->can('run');
my $starts = 0;

# A selected verdict runs twice, and a failed test can repeat alone once during each attempt.
my %visit_limit = ( 2 => 4, 3 => 2, 4 => 0 );
my %test_runs;
{
    no warnings 'redefine';
    local *Test::Mutation::Pool::run = sub (%options) {
        for my $operation (qw(next done)) {
            my $callback = $options{$operation};
            $options{$operation} = sub (@arguments) {
                my ( $ended, $task ) = Bounded::ended( 3, sub { return scalar $callback->(@arguments) } );
                die "the runner did not finish its $operation callback\n" unless $ended;
                if ( $operation eq 'next' && $task && ( $task->{payload}{kind} || q{} ) eq 'test' ) {
                    my $line = $task->{payload}{job}{mutant}->from->[0];
                    die "line $line repeated its test past confirmation\n" if ++$test_runs{$line} > $visit_limit{$line};
                }
                die "the runner kept scheduling work for three finite mutants\n" if $task && ++$starts > 30;
                return $task;
            };
        }

        # The first call can install a compiled signature in the package symbol.
        local *Test::Mutation::Pool::run = $pool;
        return $pool->(%options);
    };
    my ($result) = run_fixture( $root, mutant => \@ids, jobs => 2, cache => 0 );
    is [ map { [ $_->{mutant}->from->[0], $_->{status} ] } $result->entries->@* ],
      [ [ 2, 'Killed' ], [ 3, 'Survived' ], [ 4, 'NoCoverage' ] ],
      'the detected, surviving, and unreached changes each reach their own verdict';
    ok $result->stats->{compiles} > 0, 'the finite run also completes its compiler comparisons';
}
is $test_runs{3}, 2, 'the surviving change runs its single test once in each of its two attempts';
ok $starts > 0, 'the test observed real scheduled work';
done_testing;
