use v5.36;
use Test2::V0;
use Cwd        ();
use File::Path ();
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(write_file);
use Raised;
use Test::Mutation::Launch;
use Test::Mutation::Settings;

my $root       = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $shim       = "$root/with space:colon";
my $instrument = { generation => 3, directory => $shim, record => "$root/records", spec => "$root/list" };
my $base       = {
    root    => $root,
    perl    => $^X,
    program => 't/check.t',
    tmp     => "$root/tmp",
    lib     => ['lib'],
    env     => { PERL5LIB => '/parent/one:/parent/two', PERL5OPT => '-w' },
    switch  => [ '-I', 'local lib', '-Ilib', '-I inc', '-Mlib=local lib,more', '-W' ],
};

sub launch (%overrides) { return Test::Mutation::Launch::test_command( $base->%*, %overrides ) }

my $plain = launch();
is $plain->{command}, [ $^X, '-W', 't/check.t' ], 'a child inherits the ordinary library search path';
is $plain->{env}{PERL5LIB}, "$root/lib:$root/local lib:$root/inc:$root/more:/parent/one:/parent/two",
  'the first occurrence of each project library precedes the inherited libraries';
is $plain->{env}{PWD},             $root,                 'the process sees its working directory';
is $plain->{env}{TMPDIR},          "$root/tmp",           'the process receives its own temporary directory';
is $plain->{env}{HARNESS_ACTIVE},  1,                     'the harness is active';
is $plain->{env}{HARNESS_VERSION}, TAP::Harness->VERSION, 'the version of the installed harness is available';
ok !exists $plain->{env}{PERL_DL_NONLAZY}, 'a pure Perl project keeps its loader settings';
is launch( lib => ['blib/arch'] )->{env}{PERL_DL_NONLAZY}, 1, 'a built library enables eager loading';
is launch( lib => ['lib:old'], switch => [] )->{command}, [ $^X, "-I$root/lib:old", 't/check.t' ],
  'a path containing the environment separator travels as one argument';

is launch( switch => [qw(-Ilib -Ilib -I)], lib => [], env => {} )->{command}, [ $^X, '-I', 't/check.t' ],
  'a trailing include switch retains the interpreter argument boundary';
is launch( switch => [qw(-Ilib -Ilib)], lib => [], env => {} )->{env}{PERL5LIB}, "$root/lib",
  'repeated library paths occur once';
my $taint = launch(
    first     => "#!perl -wt\n",
    env       => { $base->{env}->%*, PERL5OPT => q{-w "-I/parent with space"} },
    arguments => ['-c']
);
is $taint->{command},
  [
    $^X, '-W', '-t',
    map( { "-I$_" } "$root/lib", "$root/local lib", "$root/inc", "$root/more", '/parent/one', '/parent/two' ),
    '-w', '-I/parent with space',
    '-c', 't/check.t'
  ],
  'the shebang, inherited libraries and quoted interpreter options also apply to a compilation';
ok !exists $taint->{env}{PERL5LIB}, 'taint leaves the inherited library variable alone';
is launch( switch => ['-T'], first => '#!perl -T', lib => [], env => {}, shim => $instrument )->{command},
  [ $^X, '-T', "-I$shim", '-MTest::Mutation::Shim::G3', 't/check.t' ], 'taint loads the task shim explicitly once';

write_file( "$shim/Test/Mutation/Shim/G3.pm", "package Test::Mutation::Shim::G3;\nsub number { 3 }\n1;\n" );
my $child = launch( shim => $instrument, env => {}, lib => [], switch => [] );
{
    local %ENV = ( %ENV, $child->{env}->%* );
    delete $ENV{PERL5LIB};
    open my $out, q{-|}, $^X, '-e', 'print Test::Mutation::Shim::G3::number()' or die "start: $!";
    my $number = readline $out;
    ok close($out), 'a child can load the shim after deleting its inherited module path';
    is $number, '3', 'the child loaded the current generation from a directory with whitespace and a colon';
}
is $child->{env}{TEST_MUTATION_ROOT},      $root,                 'the shim identifies the project that owns the task';
is $child->{env}{TEST_MUTATION_RECORD_G3}, $instrument->{record}, 'generation-specific records belong to this task';

is Test::Mutation::Launch::defaults($root), { lib => ['lib'], switch => [] }, 'default library of a pure Perl project';
write_file( "$root/.proverc", "-b -W -t\n-I 'inc dir'\n" );
is Test::Mutation::Launch::defaults($root), { lib => [ qw(blib/lib blib/arch), 'inc dir' ], switch => [ '-t', '-W' ] },
  'prove parses the project defaults';
my $config = Test::Mutation::Settings::of_call( { root => $root, switch => ['-w'] } );
is $config->lib,    [ qw(blib/lib blib/arch), 'inc dir' ], 'the library layer falls back to prove';
is $config->switch, ['-w'],                                'explicit switches take precedence over prove';
write_file( "$root/.proverc", "-w\n" );
is Test::Mutation::Launch::defaults($root)->{switch}, ['-w'], 'prove can request ordinary Perl warnings';
{
    my $before = Getopt::Long::Configure();
    no warnings qw(redefine once);
    local *App::Prove::process_args = sub {
        Getopt::Long::Configure( 'no_auto_abbrev', 'pass_through' );
        die "invalid test harness options\n";
    };
    is Raised::error( sub { Test::Mutation::Launch::defaults($root) } ),
      [ 'usage', 'input-malformed', '.proverc: invalid test harness options' ],
      'a malformed project harness configuration keeps its diagnostic';
    is Getopt::Long::Configure(), $before, 'a failure also restores the command-line parser configuration';
}
write_file( "$root/.proverc", "--exec elsewhere\n" );
is Raised::error( sub { Test::Mutation::Launch::defaults($root) } )->[1], 'prove-exec-unsupported',
  'an external executor cannot provide Perl mutation observations';

done_testing;
