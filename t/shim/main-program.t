use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file run_perl all_records lib_dir);

my $root   = project();
my $script = <<'PERL';
#!/usr/bin/env perl
use strict;
use warnings;
sub unused {
    return 7;
}
my $line = __LINE__;
print join(q{|}, $0, __FILE__, $line, scalar <DATA>);
__DATA__
body
PERL
my $path = write_file( "$root/bin/tool", $script );
write_file( "$root/spec", "trace\t1\nplaced\t1\nroot\t$root\ntarget\t$path\t$path\n" );
my $run = run_perl(
    root => $root,
    env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" },
    args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', 'bin/tool' ],
);
is $run->{status}, 0, 'the command completes' or diag $run->{stderr};
is $run->{stdout}, "bin/tool|bin/tool|7|body\n",
  'the filter preserves paths, physical line numbers, and the data handle';
my @records = @{ all_records($root) };
my %hits    = map { $_->[2] => 1 } grep { $_->[0] eq 'hit' && $_->[1] eq $path } @records;
ok $hits{7} && $hits{8}, 'the command records both executed statements';
ok !$hits{5},            'the unused subroutine has no hit';
my ($lines) = map { $_->[2] } grep { $_->[0] eq 'lines' && $_->[1] eq $path } @records;
like defined $lines ? $lines : q{}, qr/(?:\A|,)5(?:,|\z)/, 'the unused statement is breakable';
done_testing;
