use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(all_records lib_dir project run_perl write_file);

subtest 'an unquotable load path keeps its on-disk behavior in a placed run' => sub {
    for my $placed ( 0, 1 ) {
        my $root   = project();
        my $name   = 'quoted"dir';
        my $source = write_file( "$root/$name/Quoted.pm", "package Quoted; sub answer { 11 } 1;\n" );
        my $copy   = write_file( "$root/mutant",          "package Quoted; sub answer { 22 } 1;\n" );
        write_file( "$root/spec",    "trace\t0\nplaced\t$placed\ntarget\t$source\t$copy\n" );
        write_file( "$root/test.pl", "require Quoted; print Quoted::answer(), qq{\\n};\n" );
        my $run = run_perl(
            root => $root,
            args => [ '-I' . lib_dir(), "-I$name", '-MTest::Mutation::Shim', 'test.pl' ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
        );
        is $run->{status}, 0, 'an unquotable include path remains loadable' or diag $run->{stderr};
        is $run->{stdout}, $placed ? "11\n" : "22\n", 'only in-place interception serves alternate bytes';
    }
};

subtest 'each pending source keeps tracing until its own witness runs' => sub {
    my $root = project();
    write_file( "$root/pending.pl", <<'PERL' );
use strict;
use warnings;
use Test::Mutation::Shim ();
Test::Mutation::Shim::trace_source(0, 'A.pm', 'physical-A', 'records', 0);
my (@start) = glob 'records/*.rec';
print 'started=', scalar @start, "\n";
Test::Mutation::Shim::trace_source(1, 'B.pm', 'physical-B', 'records', 0);
Test::Mutation::Shim::_trace_compile(0);
print 'both=', $^P & 6, "\n";
Test::Mutation::Shim::seen(1);
print 'one=', $^P & 6, "\n";
Test::Mutation::Shim::seen(0);
print 'done=', $^P & 6, "\n";
PERL
    my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'pending.pl' ] );
    is $run->{status}, 0, 'interleaved sources can finish in reverse order' or diag $run->{stderr};
    is $run->{stdout}, "started=1\nboth=6\none=6\ndone=0\n",
      'pending compilations own the debugger flags and the start record';
    my @targets = map { $_->[1] } grep { $_->[0] eq 'lines' } @{ all_records($root) };
    is_deeply \@targets, [qw(B.pm A.pm A.pm B.pm)], 'finishing the first witnessed source still visits every target';
};

subtest 'eval tracing sets both filename flags in the test interpreter' => sub {
    for my $eval ( 0, 1 ) {
        my $root = project();
        write_file( "$root/eval.pl", <<'PERL' );
use strict;
use warnings;
use Test::Mutation::Shim ();
Test::Mutation::Shim::activate({trace => 1, trace_eval => shift, observe => 1, targets => []}, 'records');
print $^P & 0xc00, "\n";
PERL
        my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'eval.pl', $eval ] );
        is $run->{stdout}, ( $eval ? 0xc00 : 0 ) . "\n", 'the eval flags follow the spec';
    }
};

subtest 'witnesses distinguish served targets from unseen targets with and without a tracer' => sub {
    for my $blind ( 0, 1 ) {
        my $root   = project();
        my $module = write_file( "$root/lib/Module.pm", "package Module;\n1;\n" );
        write_file( "$root/spec",             "trace\t$blind\ntarget\t$module\t$module\n" );
        write_file( "$root/OtherDebugger.pm", "package DB; sub DB {} 1;\n" );
        write_file( "$root/witness.pl",       <<'PERL' );
use strict;
use warnings;
Test::Mutation::Shim::seen(0);
require Module;
Test::Mutation::Shim::seen(0);
PERL
        my @args = ( '-I' . lib_dir(), '-I.', '-Ilib' );
        push @args, '-MOtherDebugger' if $blind;
        my $run = ShimHarness::run_bare(
            root => $root,
            args => [ @args, '-MTest::Mutation::Shim', 'witness.pl' ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
        );
        is $run->{status}, 0, 'the registered module loads with either debugger setting' or diag $run->{stderr};
        my @states = map { [ $_->[0], defined $_->[2] ? $_->[2] : q{} ] }
          grep { defined $_->[1] && $_->[1] eq $module } @{ all_records($root) };
        my $observed = $blind ? 'blind' : 'seen';
        is_deeply \@states, [ [ 'blind', q{} ], [ 'seen', 'opened' ], [ $observed, q{} ], [ $observed, q{} ] ],
          'both compilation and the explicit witness report their own observations';
    }
};

done_testing;
