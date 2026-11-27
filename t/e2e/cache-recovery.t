use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(ran write_file);
use Test::Mutation::Source;

my $root = File::Temp::tempdir( CLEANUP => 1 );
write_file( "$root/lib/Example.pm", "package Example; sub sum { return \$_[0] + \$_[1] } 1;\n" );
write_file( "$root/t/example.t",    "use Test::More tests => 1; use Example; is Example::sum(1, 2), 3;\n" );
my $store   = "$root/.mutation/measurement.sqlite";
my $foreign = "contents of a different file\n";
write_file( $store, $foreign );
like ran( 2, $root, 'run', '--undetected' )->{stderr}, qr/no completed measurement/,
  'reading the foreign file finds no recorded scope';
like ran( 5, $root, 'baseline' )->{stderr}, qr/\Q$store\E.*--no-cache.*--cache-dir/,
  'the measurement explains how to preserve the foreign file';
ran( 0, $root, 'baseline', '--no-cache' );
ran( 0, $root, 'baseline', '--cache-dir', 'other-cache' );
ok -f "$root/other-cache/measurement.sqlite", 'the alternative directory holds a usable database';
is Test::Mutation::Source::read_bytes($store), $foreign, 'both recovery commands leave the foreign file untouched';
done_testing;
