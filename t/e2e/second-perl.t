use v5.36;
use Test2::V0;
use lib 't/e2e/lib', 't/lib';
use Capability;
use Fixture qw(copy_of run_fixture);

# The driver and the tests may run on different interpreters, and the shim must work in the second one.

# TEST_MUTATION_SECOND_PERL names the interpreter, and a wrong name there must fail the test and never skip it.
my $named = $ENV{TEST_MUTATION_SECOND_PERL};
my $other = $named || '/usr/bin/perl';
die "TEST_MUTATION_SECOND_PERL names no interpreter: $named\n" if $named && !-x $named;

my $version = -x $other ? qx{$other -e 'print \$]'} : $];
Capability::need( 'second-perl', $version != $], "no interpreter of another version at $other" );

my ($result) = run_fixture( copy_of('calc'), perl => $other );
is $result->baseline_failures, [], "the unmodified run passes on Perl $version";
my $counts = $result->tally->{counts};
is { $counts->%{qw(Killed Survived NoCoverage)} }, { Killed => 13, Survived => 3, NoCoverage => 3 },
  'the statuses match a run on the interpreter of the driver';

done_testing;
