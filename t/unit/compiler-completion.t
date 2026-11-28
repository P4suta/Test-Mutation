use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(write_file);
use Test::Mutation::Runner;

my $tmp = File::Temp::tempdir( CLEANUP => 1 );
for my $case (
    [ 'syntax-mutant',   { exit       => 25 },                 ".\n",  1, 0 ],
    [ 'syntax-mutant',   { exit       => 25 },                 "ab\n", 0, 1 ],
    [ 'syntax-mutant',   { signal     => 9 },                  ".\n",  0, 1 ],
    [ 'syntax-mutant',   { timed_out  => 1 },                  ".\n",  0, 1 ],
    [ 'syntax-mutant',   { overflowed => 1 },                  ".\n",  0, 1 ],
    [ 'syntax-mutant',   { exit       => 25, timed_out => 1 }, ".\n",  0, 1 ],
    [ 'code-mutant',     { exit       => 25 },                 ".\n",  0, 0 ],
    [ 'syntax-original', { exit       => 25 },                 ".\n",  0, 1 ],
    [ 'code-original',   { exit       => 25 },                 ".\n",  0, 1 ],
  )
{
    my ( $kind, $outcome, $record, $known, $missing ) = @$case;
    write_file( "$tmp/inputs", $record );
    my ( $run, $job, $result ) = ( {}, {}, {%$outcome} );
    my $task = { payload => { tmp => $tmp, kind => $kind }, env => { TEST_MUTATION_COMPILER_READS => q{} } };
    Test::Mutation::Runner::_remember_compiler_inputs( $run, $job, $task, $result );
    my $label = join q{ }, $kind, sort keys %$outcome;
    is $result->{compiler_inputs}, $known ? {} : undef, "$label checks the record of the performed compilation";
    is $run->{missing_compiler_inputs} || 0, $missing,  "$label preserves the completeness of the run";
    ok $job->{unbound_compiler}, "$label requires the mutant to be checked again";
}

done_testing;
