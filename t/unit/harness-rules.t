use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(write_file);
use Raised;
use Test::Mutation::Schedule;

my $project  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $caller   = Cwd::getcwd();
my $serial   = "---\nseq: 't/*.t'\n";
my $parallel = "---\npar: 't/*.t'\n";
local $ENV{HARNESS_RULESFILE} = undef;
delete $ENV{HARNESS_RULESFILE};
is Test::Mutation::Schedule::rules($project), undef, 'a project without a rules file uses the harness default';
write_file( "$project/t/testrules.yml", $serial );
is Test::Mutation::Schedule::rules($project), { seq => 't/*.t' }, 'the test directory supplies the fallback rules';
write_file( "$project/testrules.yml", $parallel );
is Test::Mutation::Schedule::rules($project), { par => 't/*.t' },
  'the project rules have precedence over the test directory';
write_file( "$project/0", $serial );

for my $file ( '0', "$project/0" ) {
    local $ENV{HARNESS_RULESFILE} = $file;
    is Test::Mutation::Schedule::rules($project), { seq => 't/*.t' },
      'the environment selects either a project-relative path or an absolute path';
}
for my $absent ( q{}, 'missing.yml' ) {
    local $ENV{HARNESS_RULESFILE} = $absent;
    is Test::Mutation::Schedule::rules($project), undef, 'an explicitly absent rules file disables the defaults';
}
local $ENV{HARNESS_RULESFILE} = 'invalid.yml';
write_file( "$project/invalid.yml", "---\nmode: unexpected\n" );
my $error = Raised::error( sub { Test::Mutation::Schedule::rules($project) } );
is $error->[1], 'input-malformed', 'an invalid rule cannot schedule a test';
like $error->[2], qr{\Q$project/invalid.yml\E}, 'the error identifies the selected file';
like $error->[2], qr/HarnessRule/,              'an invalid rule is identified by its structural contract';
write_file( "$project/invalid.yml", "---\npar: 't/{a,b'\n" );
my $pattern_error = Raised::error( sub { Test::Mutation::Schedule::rules($project) } );
is $pattern_error->[1], 'input-malformed', 'the scheduler checks path patterns before there are tests to run';
like $pattern_error->[2], qr{\Q$project/invalid.yml\E}, 'a malformed pattern identifies its rules file';
like dies { Test::Mutation::Schedule::rules( [] ) }, qr/type constraint "Str"/, 'a rules directory must be a path';
like dies { Test::Mutation::Schedule::queue( undef, [ [] ] ) }, qr/type constraint/,
  'every scheduled test must be a path';
like dies { Test::Mutation::Schedule::compatible( undef, 't/a.t', 't/b.t' ) }, qr/type constraint/,
  'compatibility requires an explicit project rule';
is Cwd::getcwd(), $caller, 'resolving project-relative rules preserves the calling directory';

done_testing;
