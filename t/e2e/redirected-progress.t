use v5.36;
use Test2::V0;
use File::Temp ();
use IO::Handle ();
use lib 't/e2e/lib', 't/contract/lib';
use Fixture qw(write_file);
use World;
use Test::Mutation::Source;

my $root = File::Temp::tempdir( CLEANUP => 1 );
my $log  = "$root/operand.txt";
write_file( "$root/lib/Sum.pm", 'package Sum; sub add { return $_[0] + $_[1] } 1;' );
write_file( "$root/t/sum.t",    <<'TEST' );
use Test::More tests => 2;
use Sum;
open my $input, '<', 'operand.txt' or die $!;
is do { local $/; readline $input }, "retained\n", 'the test sees the previous output bytes';
is Sum::add(1, 2), 3, 'addition';
TEST

sub redirected () {
    open my $errors, '>>:encoding(UTF-8)', $log or die "append $log: $!";
    $errors->autoflush(1);
    open my $output, '>', \my $terminal or die "open output: $!";
    my $world = { World::facts( cwd => $root ), out => $output, err => $errors };
    my $plan  = Test::Mutation::CLI::plan( argv => [ 'run', '--jobs', '1', '--format', 'terminal' ], world => $world );
    my $exit  = Test::Mutation::CLI::execute( $plan, $world );
    close $errors or die "close $log: $!";
    close $output or die "close output: $!";
    return ( $exit, Test::Mutation::Source::read_bytes($log) );
}

write_file( $log, "retained\n" );
my ( $exit, $progress ) = redirected();
is $exit, 0, 'appending CLI progress preserves the input copied for the tests';
like $progress, qr/\Aretained\nResolve.*?^Copy .*?^Baseline /ms,
  'the original file contents precede the progress lines in event order';
done_testing;
