use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(all_records lib_dir project run_perl write_file);

my $root   = project();
my $source = write_file( "$root/lib/Listed.pm", "package Listed; sub value { return 1 } 1;\n" );
write_file( "$root/extra/Discovered.pm", "package Discovered; sub value { return 2 } 1;\n" );
write_file( "$root/spec",                "includes\t1\ntrace\t0\ntarget\t$source\t$source\n" );
write_file( "$root/probe.pl",            <<'PERL' );
BEGIN { unshift @INC, sub { return }, 'lib', 'lib' }
sub included {
    my ($name) = glob 'records/*.inc';
    return () unless defined $name;
    open my $file, '<', $name or die "open $name: $!";
    my @paths = map { chomp; pack 'H*', $_ } <$file>;
    close $file or die "close $name: $!";
    return @paths;
}
print "at startup=", scalar(included()), "\n";
require Listed;
my @before = included();
lib->import('extra');
push @INC, 'after-duplicate';
require Discovered;
my @after = included();
my %times;
$times{$_}++ for @after;
my %before = map { $_ => 1 } @before;
print "new=", join(',', grep { !$before{$_} } @after), "\n";
print "lib=", $times{"$ENV{PROJECT}/lib"} || 0, " extra=", $times{"$ENV{PROJECT}/extra"} || 0, " empty=", $times{q{}} || 0, "\n";
print "result=", Listed::value() + Discovered::value(), "\n";
PERL
my $ran = run_perl(
    root => $root,
    env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records", PROJECT => $root },
    args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', 'probe.pl' ]
);
is $ran->{status}, 0, 'library discovery preserves the program' or diag $ran->{stderr};
like $ran->{stdout}, qr/^at startup=[1-9]\d*$/m, 'the initial include paths exist before the first dynamic require';
like $ran->{stdout}, qr/^new=\Q$root\/extra,$root\/after-duplicate\E$/m,
  'a later require captures a library added since activation';
like $ran->{stdout}, qr/^lib=1 extra=1 empty=0$/m, 'paths are absolute and unique across loads and coderefs';
like $ran->{stdout}, qr/^result=3$/m,              'both modules ran';
is_deeply [ grep { $_->[0] eq 'error' } @{ all_records($root) } ], [], 'recording includes completed successfully';

my $failing = project();
write_file( "$failing/fail.pl", <<'PERL' );
use Test::Mutation::Shim ();
mkdir "records/$$.inc" or die "create obstacle: $!";
Test::Mutation::Shim::activate({ includes => 1, targets => [] }, 'records');
PERL
my $failed = run_perl( root => $failing, args => [ '-I' . lib_dir(), 'fail.pl' ] );
is $failed->{status}, 0, 'the test can finish when the include list cannot be opened';
my @error = grep { $_->[0] eq 'error' } @{ all_records($failing) };
like $error[0][2], qr/^cannot record includes:/, 'the include write failure reaches the process record';
my $closing = project();
write_file( "$closing/close.pl", <<'PERL' );
use strict;
use warnings;
our $observing;
BEGIN {
    *CORE::GLOBAL::close = sub (;*) {
        my $closed = CORE::close($_[0]);
        return $closed unless $observing;
        $! = 5;
        return 0;
    };
}
use Cwd ();
use Test::Mutation::Shim ();
$observing = 1;
Test::Mutation::Shim::activate({ includes => 1, observe => 1, targets => [] }, 'records');
$observing = 0;
PERL
my $unclosed = run_perl( root => $closing, args => [ '-I' . lib_dir(), 'close.pl' ] );
is $unclosed->{status}, 0, 'a close error is recorded without stopping the measured program';
my @closing = grep { $_->[0] eq 'error' } @{ all_records($closing) };
like $closing[0][2], qr/^cannot close includes: /, 'a failed include-list close is observable';
done_testing;
