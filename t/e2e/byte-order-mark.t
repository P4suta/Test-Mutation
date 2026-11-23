use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture statuses write_file);

# Perl accepts a byte order mark before the first line, and some editors write one.

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $mark = "\xEF\xBB\xBF";
write_file( "$root/lib/Marked.pm",
    $mark . "package Marked;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n1;\n" );
write_file( "$root/t/marked.t",
    "use Test::More tests => 1;\nuse Marked;\nis Marked::next_one(2), 3, 'the next one';\n" );

my ($result) = run_fixture($root);
is $result->problems,          [], 'the file is analyzed';
is $result->baseline_failures, [], 'the unmodified run passes';
is statuses($result),
  {
    'lib/Marked.pm:4 removed the body of next_one' => 'Killed',
    'lib/Marked.pm:4 removed the return value'     => 'Killed',
    'lib/Marked.pm:4 replaced + with -'            => 'Killed',
  },
  'the mutants of a file with a mark are measured';

done_testing;
