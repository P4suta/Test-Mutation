use v5.36;
use Test2::V0;
use JSON::PP ();

# The release gate reads the report of a run of the tool on its own sources.
# `mise run mutation-gate` writes the report and then runs this file.

my $path = 'mutation-report/mutation.json';
open my $handle, '<:raw', $path or bail_out("no report at $path: run `mise run mutation-gate`");
my $report = JSON::PP->new->utf8->decode( do { local $/ = undef; readline $handle } );
close $handle or die "close $path: $!";

my %mutants = map { $_ => $report->{files}{$_}{mutants} } keys $report->{files}->%*;
my @library = sort glob 'lib/Test/Mutation.pm lib/Test/Mutation/*.pm lib/Test/Mutation/*/*.pm lib/Test/*.pm';
my @absent  = grep { !$mutants{$_} } @library;
is \@absent, [], 'the report covers every library file';

# The facts beside each mutant keep its status in the run, which the schema writes another way for a timeout.
my $status_of = sub ($mutant) { return $mutant->{testMutation}{status} };
my @all       = map { $_->@* } values %mutants;
is scalar( grep { $status_of->($_) eq 'Pending' } @all ),   0, 'the run finished';
is scalar( grep { $status_of->($_) eq 'NoVerdict' } @all ), 0, 'every mutant has a verdict';

my @served = grep { $status_of->($_) =~ /\A(?:Killed|Survived|Timeout)\z/ } $mutants{'lib/Test/Mutation/Shim.pm'}->@*;
ok scalar(@served), 'the tests loaded mutants of the shim' or diag 'every mutant of the shim is without coverage';

done_testing;
