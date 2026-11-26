use v5.36;
use Test2::V0;
use Cwd ();
use Test::Mutation::Schedule;

my @tests    = qw(t/a.t t/b.t);
my $parallel = { par => [ { seq => 't/a.t' }, 't/b.t' ] };
my $serial   = { seq => [ { par => ['t/a.t'] }, 't/b.t' ] };
ok Test::Mutation::Schedule::compatible( $parallel, @tests ), 'different parallel branches may overlap';
ok !Test::Mutation::Schedule::compatible( $serial,  @tests ), 'successive serial branches wait';
ok Test::Mutation::Schedule::queue( undef, \@tests )->get_job, 'the default scheduler accepts an absent rule';
my $cycle = { seq => [] };
push $cycle->{seq}->@*, $cycle;

for my $rule (
    {},
    { all => 't/*.t' },
    { seq => [], par => [] },
    { par => undef },
    { seq => [ { par => {} } ] },
    { par => [undef] }, $cycle
  )
{
    local $SIG{ALRM} = sub { die "the scheduler did not reject the rule\n" };
    alarm 1;
    my $error = dies { Test::Mutation::Schedule::compatible( $rule, @tests ) };
    alarm 0;
    like $error, qr/type constraint/, 'invalid rules fail at the boundary';
}
pop $cycle->{seq}->@*;

subtest 'the distribution checks its smallest observable contracts before nested measurements' => sub {
    delete local $ENV{HARNESS_RULESFILE};
    my $rules = Test::Mutation::Schedule::rules( Cwd::getcwd() );
    my @input = qw(t/e2e/work.t t/contract/reasons.t xt/example.t t/shim/trace.t
      t/unit/runner-work.t t/discovery/oracles.t t/assumptions/tools.t);
    my @ordered = map { $_->filename } Test::Mutation::Schedule::queue( $rules, \@input )->get_all;
    is \@ordered, [ @input[ 4, 3, 6, 1, 5, 0, 2 ] ], 'every selected path runs in its declared group';
    ok Test::Mutation::Schedule::compatible( $rules, @input[ 0, 4 ] ),
      'compiling and running independent tests in different groups can overlap';
    ok Test::Mutation::Schedule::compatible( $rules, $input[0], $input[0] ),
      'the project imposes no serial lock on independent mutant copies';
};

done_testing;
