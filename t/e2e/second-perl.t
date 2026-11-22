use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture);

# The driver and the tests may run on different interpreters, and the shim must work in the second one.

my $other = '/usr/bin/perl';
skip_all 'no second interpreter at /usr/bin/perl' if !-x $other;

my $version = qx{$other -e 'print \$]'};
skip_all 'the second interpreter is the one that runs this test' if $version == $];

my ($result) = run_fixture( copy_of('calc'), perl => $other );
is $result->baseline_failures, [], "the unmodified run passes on Perl $version";
my $counts = $result->tally->{counts};
is { $counts->%{qw(Killed Survived NoCoverage)} }, { Killed => 13, Survived => 3, NoCoverage => 3 },
  'the statuses match a run on the interpreter of the driver';

done_testing;
