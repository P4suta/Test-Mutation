use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(copy_of leftovers ran run_fixture);
use Gate;

# The helpers are the judge of every end-to-end test, so they reject a wrong exit status and a run that leaves files.

my $root = copy_of('calc');

subtest 'a run with the expected status passes and returns its output' => sub {
    my $run;
    is Gate::outcomes( sub { $run = ran( 0, $root, 'list' ) } ), [ 'pass', 'pass' ], 'the status and the leftovers';
    like $run->{stdout}, qr/^19 mutants$/m, 'standard output comes back';
    is $run->{stderr}, q{}, 'and so does standard error';
    is $run->{exit},   0,   'and the exit status';
};

subtest 'the helper rejects another exit status' => sub {
    is Gate::outcomes( sub { ran( 0, $root, '--no-such-option' ) } ), [ 'fail', 'pass' ],
      'a usage error where success was expected';
    is Gate::outcomes( sub { ran( 2, $root, 'list' ) } ), [ 'fail', 'pass' ],
      'success where a usage error was expected';
    is Gate::outcomes( sub { ran( 2, $root, '--no-such-option' ) } ), [ 'pass', 'pass' ], 'the expected usage error';
};

subtest 'the helper rejects a run that leaves an entry behind' => sub {
    my ($id) = ran( 0, $root, 'list' )->{stdout} =~ /\A([0-9a-f]{12})/;
    my $leaving = sub ($code) { return ( 'exec', $id, '--', $^X, '-e', $code ) };
    is Gate::outcomes( sub { ran( 0, $root, $leaving->('1') ) } ), [ 'pass', 'pass' ], 'a command that writes nothing';
    is Gate::outcomes( sub { ran( 0, $root, $leaving->('open my $left, q{>}, "$ENV{TMPDIR}/left" or die') ) } ),
      [ 'pass', 'fail' ], 'a file in the temporary directory';
    is Gate::outcomes( sub { ran( 0, $root, $leaving->('mkdir q{.mutation}; mkdir q{.mutation/run-left} or die') ) } ),
      [ 'pass', 'fail' ], 'a work directory in the project';
    is Gate::outcomes( sub { ran( 0, $root, '--jobs', 2, '--format', 'terminal', '--keep-work' ) } ),
      [ 'pass', 'fail' ],
      'a work directory that the run was told to keep counts too';
};

subtest 'the leftovers name what a run left' => sub {
    my $temporary = File::Temp::tempdir( CLEANUP => 1 );
    my $project   = File::Temp::tempdir( CLEANUP => 1 );
    is leftovers( $temporary, $project ), [], 'two empty places';
    mkdir "$temporary/mutation-abc" or die "mkdir: $!";
    mkdir "$project/.mutation"      or die "mkdir: $!";
    is leftovers( $temporary, $project ), ['mutation-abc in the temporary directory'],
      'an entry of the temporary directory';
    mkdir "$project/.mutation/run-abc" or die "mkdir: $!";
    is leftovers( $temporary, $project ),
      [ 'mutation-abc in the temporary directory', '.mutation/run-abc in the project' ],
      'and a work directory';
    is leftovers( $temporary, $project, 'mutation-abc in the temporary directory' ),
      ['.mutation/run-abc in the project'],
      'an entry that stood there before the run is no leftover';
    open my $cache, '>', "$project/.mutation/cache.json" or die "write: $!";
    close $cache                       or die "close: $!";
    rmdir "$project/.mutation/run-abc" or die "rmdir: $!";
    rmdir "$temporary/mutation-abc"    or die "rmdir: $!";
    is leftovers( $temporary, $project ), [], 'the cache of a run is no leftover';
};

subtest 'a run inside the test process is checked the same way' => sub {
    my ( $result, $events );
    is Gate::outcomes( sub { ( $result, $events ) = run_fixture( copy_of('calc') ) } ), ['pass'],
      'the run leaves nothing behind';
    is scalar $result->entries->@*, 19,         'the result comes back';
    is $events->[0],                'analyzed', 'and so do the events';

    my $kept = qr/\A[.]mutation\/run-\w+ in the project\z/;
    is Gate::outcomes( sub { run_fixture( copy_of('calc'), keep_work => 1 ) } ), ['fail'],
      'a kept work directory fails';
    is Gate::outcomes( sub { run_fixture( copy_of('calc'), keep_work => 1, leaves => $kept ) } ), ['pass'],
      'unless the test expects it';
    is Gate::outcomes( sub { run_fixture( copy_of('calc'), leaves => $kept ) } ), ['fail'],
      'and an expectation that nothing meets fails';

    my $temporary = File::Temp::tempdir( CLEANUP => 1 );
    open my $file, '>', "$temporary/kept.txt" or die "write: $!";
    close $file or die "close: $!";
    is Gate::outcomes( sub { run_fixture( copy_of('calc'), temporary => $temporary ) } ), ['pass'],
      'a named temporary directory may hold entries before the run';
    like dies { run_fixture( copy_of('calc'), jobs => 0 ) }, qr/jobs/, 'an error of the run reaches the test';
    like dies { run_fixture( copy_of('calc'), no_such_setting => 1 ) }, qr/no_such_setting/,
      'and so does a setting that the run lacks';
};

done_testing;
