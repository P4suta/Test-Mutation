package Discovery::Check;
use v5.36;
use Discovery::Engine;
use Discovery::Known;

# Every invariant and every relation of the engine, each as a function from observations to the text of its violations.
# The text names a kind of violation and no mutant, path of a run, or count, so a finding reads the same on every run.

my %DECIDED    = map { $_ => 1 } qw(Killed Survived);
my %UNDETECTED = map { $_ => 1 } qw(Survived NoCoverage);

my %CHECK = (
    completes => \&_completes,
    I2        => \&_no_process,
    I3        => \&_no_leftover,
    I4        => \&_unchanged,
    I5        => \&_reasons,
    I7        => \&_truth,
);

sub names () {
    my @names = sort keys %CHECK;
    return @names;
}

sub findings ( $names, %arg ) {
    my @unknown = grep { !$CHECK{$_} } $names->@*;
    die "no check is named @unknown\n" if @unknown;
    return map { $CHECK{$_}->( \%arg ) } $names->@*;
}

sub _unique (@texts) {
    my %seen   = map { $_ => 1 } @texts;
    my @unique = sort keys %seen;
    return @unique;
}

# A project whose tests pass is measured: the run ends on its own, with status 0 and a report.
sub _completes ($arg) {
    my $run = $arg->{run};
    return 'the run exceeds its deadline'           if $run->{hung};
    return "the run ends by signal $run->{signal}"  if $run->{signal};
    return 'the unmodified run fails'               if $run->{baseline_failures}->@*;
    return "the run exits with status $run->{exit}" if $run->{exit} != 0;
    return 'the run writes no report'               if !$run->{reported};
    return;
}

sub _no_process ($arg) {
    return _unique( map { "I2 a process outlives the run: $_" } $arg->{run}{processes}->@* );
}

# The tool names its directories with a random suffix, which the text leaves out.
sub _no_leftover ($arg) {
    return _unique( map { 'I3 the run leaves ' . s/-[^ ]*/-*/r } $arg->{run}{left}->@* );
}

sub _unchanged ($arg) {
    return _unique( map { 'I4 the project changed: ' . s/[0-9]+/N/gr } $arg->{run}{changed}->@* );
}

sub _reasons ($arg) {
    my $run    = $arg->{run};
    my %listed = map { $_ => 1 } Discovery::Engine::statuses();
    my @found;
    for my $id ( keys $run->{status}->%* ) {
        my $status = $run->{status}{$id};
        my $reason = $run->{reason}{$id};
        push @found,
            !$listed{$status}                                            ? "I5 the status $status is outside the list"
          : !$DECIDED{$status} && !( defined $reason && length $reason ) ? "I5 $status carries no reason"
          :                                                                ();
    }
    return _unique(@found);
}

# `module` names the file that holds the cells, and `test_of` maps a test of the project to the test of the cells.
sub _truth ($arg) {
    my ( $run, $known ) = $arg->@{qw(run known)};
    my $module  = defined $arg->{module} ? $arg->{module} : 'lib/Known.pm';
    my $test_of = $arg->{test_of} || {};
    my @ids     = grep { $run->{mutants}{$_}{path} eq $module } keys $run->{mutants}->%*;
    my @found;
    $known->prepare( [ map { $run->{mutants}{$_} } @ids ] );
    for my $id (@ids) {
        my ( $want, $killer ) = Discovery::Known::verdict( $known->truth( $run->{mutants}{$id} ), $arg->{coverage} );
        my $got = $run->{status}{$id};
        if ( $got ne $want && !( $got eq 'Ignored' && $UNDETECTED{$want} ) ) {
            push @found, "I7 truth $want, run $got";
            next;
        }
        next if $got ne 'Killed';
        my $by = $run->{by}{$id};
        push @found,
            !defined $by                                                 ? 'I7 a killed mutant names no test'
          : !$killer->{ exists $test_of->{$by} ? $test_of->{$by} : $by } ? 'I7 the killing test passes in truth'
          :                                                                ();
    }
    return _unique(@found);
}

1;
