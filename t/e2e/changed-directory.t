use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture statuses write_file);

# prove names its library directories in full, so a test may change its directory before it loads a module.

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
write_file( "$root/lib/Late.pm",
    "package Late;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n1;\n" );
write_file( "$root/t/late.t",
        "use Test::More tests => 4;\nuse File::Temp ();\n"
      . "chdir File::Temp::tempdir( CLEANUP => 1 ) or die \$!;\n"
      . "require Late;\nis Late::next_one(2), 3, 'the next one';\n"
      . "is scalar( grep { m{\\A/.+/lib\\z} && -f \"\$_/Late.pm\" } \@INC ), 1, 'the relative directory is named in full';\n"
      . "is scalar( grep { \$_ eq '$root/elsewhere' } \@INC ), 1, 'a directory named in full stays';\n"
      . "ok \$^W, 'another switch stays';\n" );

my ($result) = run_fixture( $root, switch => [ '-Ilib', "-I$root/elsewhere", '-w' ] );
is $result->baseline_failures, [], 'the unmodified run passes';
is statuses($result),
  {
    'lib/Late.pm:4 removed the body of next_one' => 'Killed',
    'lib/Late.pm:4 removed the return value'     => 'Killed',
    'lib/Late.pm:4 replaced + with -'            => 'Killed',
  },
  'the mutants of a module that loads after the change of directory are measured';

done_testing;
