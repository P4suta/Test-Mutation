use v5.36;
use Test2::V0;
use File::Temp ();
use IO::Handle ();
use lib 't/e2e/lib', 't/contract/lib';
use Fixture qw(write_file);
use World;
use Test::Mutation::Source;
use Test::Mutation::Tree;

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

sub redirected (@options) {
    open my $errors, '>>:encoding(UTF-8)', $log or die "append $log: $!";
    $errors->autoflush(1);
    open my $output, '>', \my $terminal or die "open output: $!";
    my $world = { World::facts( cwd => $root ), out => $output, err => $errors };
    my $plan =
      Test::Mutation::CLI::plan( argv => [ 'run', '--jobs', '1', '--format', 'terminal', @options ], world => $world );
    my $exit = Test::Mutation::CLI::execute( $plan, $world );
    close $errors or die "close $log: $!";
    close $output or die "close output: $!";
    return ( $exit, Test::Mutation::Source::read_bytes($log) );
}

write_file( $log, "retained\n" );
my ( $exit, $progress ) = redirected();
is $exit, 0, 'appending CLI progress preserves the input copied for the tests';
like $progress, qr/\Aretained\nResolve.*?^Copy .*?^Baseline /ms,
  'the original file contents precede the progress lines in event order';

subtest 'another writer changes the same regular file while the CLI prepares its copy' => sub {
    write_file( $log, "retained\n" );
    my $copy = \&Test::Mutation::Tree::copy;
    no warnings 'redefine';
    local *Test::Mutation::Tree::copy = sub (@arguments) {
        open my $other, '>>:raw', $log or die "append $log: $!";
        print {$other} "external\n";
        close $other or die "close $log: $!";
        return $copy->(@arguments);
    };
    my ( $code, $text ) = redirected('--no-cache');
    is $code, 5, 'the independent append invalidates the copy';
    like $text, qr/\Aretained\nexternal\nResolve.*?^Release .*?measurement inputs changed/ms,
      'the CLI flushes progress before its diagnostic and preserves the independent append';
};

subtest 'a linked progress file keeps its original input through validation' => sub {
    write_file( $log,            "retained\n" );
    write_file( "$root/t/sum.t", <<'TEST' );
use Test::More tests => 3;
use Sum;
ok -l 'operand.txt', 'the project input is linked';
open my $input, '<', 'operand.txt' or die $!;
is scalar readline $input, "retained\n", 'the original prefix is available through the link';
is Sum::add(1, 2), 3, 'addition';
TEST
    my ( $code, $text ) = redirected( '--no-cache', '--link', 'operand.txt' );
    is $code, 0, 'validation accepts the unchanged linked bytes';
    like $text, qr/\Aretained\nResolve.*?^Copy .*?^Baseline /ms, 'the CLI appends progress after verification';
};

done_testing;
