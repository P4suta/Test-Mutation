use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(all_records lib_dir project run_perl write_file);

sub observe_source {
    my ($mode) = @_;
    my $root   = project();
    my $path   = "$root/Tracked.pm";
    my $source = <<'PERL';
package Tracked;
BEGIN { require Test::Mutation::Shim; Test::Mutation::Shim::trace_source(3, 'lib/Original.pm', __FILE__, $ENV{RECORD_DIR}, 10) }
UNITCHECK { my $seen = Test::Mutation::Shim::seen(3); print "witness=$seen\n" }
sub unused {
    return 6;
}
sub value {
    return 8;
}
1;
PERL
    write_file( $path, $source );
    my %env  = ( RECORD_DIR => "$root/records" );
    my @args = ( '-I' . lib_dir() );
    if ( $mode eq 'debugger' ) {
        write_file( "$root/Debugger.pm", "package DB; sub DB { } 1;\n" );
        push @args, '-I.', '-MDebugger';
    }
    if ( $mode eq 'active' ) {
        write_file( "$root/spec", "trace\t1\nobserve\t1\ntarget\tlib/Original.pm\t$path\n" );
        @env{qw(TEST_MUTATION_SPEC TEST_MUTATION_RECORD)} = ( "$root/spec", "$root/records" );
        push @args, '-MTest::Mutation::Shim';
    }
    write_file( "$root/test.pl", <<'PERL' );
require './Tracked.pm';
my $unregistered = Test::Mutation::Shim::seen(99);
Tracked::value() for 1 .. 3;
Test::Mutation::Shim::mark_compiled(99);
Test::Mutation::Shim::mark_compiled(3);
print "value=", Tracked::value(), " unregistered=", defined $unregistered ? 1 : 0, "\n";
PERL
    my $ran = run_perl( root => $root, args => [ @args, 'test.pl' ], env => \%env );
    is $ran->{status}, 0,   "$mode: the program exits successfully" or diag $ran->{stderr};
    is $ran->{stderr}, q{}, "$mode: an unknown target cannot leak a warning";
    is $ran->{stdout}, "witness=1\nvalue=8 unregistered=0\n",
      "$mode: the witness acknowledges only its registered target";
    return all_records($root);
}

for my $mode (qw(fresh active)) {
    my $records = observe_source($mode);
    my @starts  = grep { $_->[0] eq 'begin' } @$records;
    is_deeply \@starts, [ [ 'begin', 1 ] ], "$mode: one traced process records its start";
    my @events = grep { defined $_->[1] && $_->[1] eq 'lib/Original.pm' } @$records;
    ok scalar( grep { $_->[0] eq 'seen' } @events ), "$mode: the original source is recorded as compiled";
    is scalar( grep { $_->[0] eq 'blind' || $_->[0] eq 'around' } @events ), 0,
      "$mode: compiling the instrumented target provides load evidence";
    my @breakable = map { [ split /,/, $_->[2] ] } grep { $_->[0] eq 'lines' } @events;
    is scalar @breakable, 2, "$mode: statement locations are recorded at compilation and at exit";

    for my $lines (@breakable) {
        my %present = map { $_ => 1 } @$lines;
        ok $present{15} && $present{18}, "$mode: the shifted line table includes both subroutine bodies";
        ok !$present{5} && !$present{8}, "$mode: physical lines are absent from the original source's line table";
    }
    my %hit = map { $_->[2] => 1 } grep { $_->[0] eq 'hit' } @events;
    is scalar( grep { $_->[0] eq 'hit' && $_->[2] == 18 } @events ), 1,
      "$mode: repetitions record one original location";
    ok $hit{18} && !$hit{15}, "$mode: only the executed, shifted body has a hit";
}
my $blind = observe_source('debugger');
ok scalar( grep { $_->[0] eq 'blind' && $_->[1] eq 'lib/Original.pm' } @$blind ),
  'the witness still records the load when another debugger owns the hook';
is scalar( grep { $_->[0] eq 'hit' || $_->[0] eq 'lines' || $_->[0] eq 'seen' } @$blind ), 0,
  'an unavailable tracer supplies no line coverage';
done_testing;
