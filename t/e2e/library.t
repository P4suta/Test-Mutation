use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Cwd     ();
use Fixture qw(copy_of);
use Permutl;

my $root = copy_of('calc');

# The listing comes first: a call that takes another project than the named one fails here within a moment.
subtest 'mutants lists the mutants without running a test' => sub {
    my $mutants = Permutl::mutants( root => $root, disable => ['sub-body'] );
    is scalar( $mutants->@* ), 15, 'the mutants of the enabled mutators';
    isa_ok $mutants->[0], ['Permutl::Mutant'], 'each element';
};

subtest 'run measures a project and returns the result' => sub {
    my @events;
    my $result = Permutl::run( root => $root, jobs => 2, on_event => sub ( $event, $data ) { push @events, $event } );
    isa_ok $result, ['Permutl::Result'], 'the result';
    is $result->tally->{counts}{Killed}, 13,         'the killed mutants';
    is $events[0],                       'analyzed', 'the listener receives the events';
};

subtest 'settings are checked' => sub {
    like dies { Permutl::run( root => $root, jobs      => 0 ) },      qr/jobs/,  'a value outside its type is refused';
    like dies { Permutl::run( root => $root, speed     => 'fast' ) }, qr/speed/, 'an unknown setting is refused';
    like dies { Permutl::run( root => $root, read_file => 1 ) }, qr/unknown setting: read_file/,
      'a function of the configuration class is not a setting';
};

subtest 'the working directory is the project when the call names no root' => sub {
    my $here = Cwd::getcwd();
    chdir $root or die "chdir: $!";
    my $mutants = eval { Permutl::mutants( disable => ['sub-body'] ) };
    my $error   = $@;
    chdir $here or die "chdir: $!";
    is scalar( @{ $mutants || [] } ), 15, 'the mutants of the project in the working directory' or diag $error;
};

ok Permutl->VERSION, 'the distribution has a version';

done_testing;
