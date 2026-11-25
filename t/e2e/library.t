use v5.36;
use Test2::V0;
use lib 't/lib';
use Raised;
use lib 't/e2e/lib';
use Cwd     ();
use Fixture qw(copy_of);
use Test::Mutation;

my $root = copy_of('calc');

# The listing comes first: a call that takes another project than the named one fails here within a moment.
subtest 'mutants lists the mutants without running a test' => sub {
    my $mutants = Test::Mutation::mutants( root => $root, disable => ['sub-body'] );
    is scalar( $mutants->@* ), 17, 'the mutants of the enabled mutators';
    isa_ok $mutants->[0], ['Test::Mutation::Mutant'], 'each element';
};

subtest 'run measures a project and returns the result' => sub {
    my @events;
    my $result =
      Test::Mutation::run( root => $root, jobs => 2, on_event => sub ( $event, $data ) { push @events, $event } );
    isa_ok $result, ['Test::Mutation::Result'], 'the result';
    is $result->tally->{counts}{Killed}, 15,         'the killed mutants';
    is $events[0],                       'analyzed', 'the listener receives the events';
};

subtest 'settings are checked' => sub {
    like dies { Test::Mutation::run( root => $root, jobs => 0 ) }, qr/jobs/, 'a value outside its type is refused';
    like Raised::error( sub { Test::Mutation::run( root => $root, speed => 'fast', hurry => 1 ) } ),
      [ 'usage', 'setting-unknown', qr/\Ahurry names no setting; the nearest is [a-z_]+\z/ ],
      'the first unknown setting in the order of the names is refused';
    is Raised::message( sub { Test::Mutation::run( root => $root, min_scor => 1 ) } ),
      'min_scor names no setting; the nearest is min_score', 'with the nearest name';
    like Raised::message( sub { Test::Mutation::run( root => $root, resolve => 1 ) } ),
      qr/\Aresolve names no setting/, 'a function of the settings is no setting';
};

subtest 'the working directory is the project when the call names no root' => sub {
    my $here = Cwd::getcwd();
    chdir $root or die "chdir: $!";
    my $mutants = eval { Test::Mutation::mutants( disable => ['sub-body'] ) };
    my $error   = $@;
    chdir $here or die "chdir: $!";
    is scalar( @{ $mutants || [] } ), 17, 'the mutants of the project in the working directory' or diag $error;
};

ok Test::Mutation->VERSION, 'the distribution has a version';

done_testing;
