package Discovery::Check;
use v5.36;
use Discovery::Engine;
use Discovery::Known;

# Every invariant and every relation of the engine, each as a function from observations to the text of its violations.
# The text names a kind of violation and no mutant, path of a run, or count, so a finding reads the same on every run.

my %DECIDED    = map { $_ => 1 } qw(Killed Survived);
my %MEASURED   = map { $_ => 1 } qw(Killed Survived NoCoverage);
my %UNDETECTED = map { $_ => 1 } qw(Survived NoCoverage);
my %PLAIN      = ( target => 'lib/Known.pm', shift => 0 );

my %CHECK = (
    completes => \&_completes,
    I2        => \&_no_process,
    I3        => \&_no_leftover,
    I4        => \&_unchanged,
    I5        => \&_reasons,
    I6        => \&_reported,
    I7        => \&_truth,
    I8        => \&_same_under_styles,
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

# The mutants in the cells of a member, each under the place and the replacement that every member shares.
# A member holds its cells in `target`, `shift` lines below their place in the module, and asserts them in `test`.
sub _cells ( $run, $known, $member ) {
    my %mutant;
    for my $id ( keys $run->{mutants}->%* ) {
        my $mutant = $run->{mutants}{$id};
        next if $mutant->{path} ne $member->{target};
        my %moved = ( $mutant->%*, map { $_ => $mutant->{$_} - $member->{shift} } qw(line end_line) );
        next if !$known->holds( $moved{line} );
        $mutant{ Discovery::Known::key( \%moved ) } = { %moved, id => $id };
    }
    return \%mutant;
}

sub _verdicts ( $known, $cells, $coverage ) {
    $known->prepare( [ values $cells->%* ] );
    return { map { $_ => [ Discovery::Known::verdict( $known->truth( $cells->{$_} ), $coverage ) ] } keys $cells->%* };
}

sub _differs ( $want, $got ) {
    return $got ne $want && !( $got eq 'Ignored' && $UNDETECTED{$want} ) ? 1 : 0;
}

# The statuses of the cells equal their truth, and the test that kills a mutant kills it in truth.
sub _truth ($arg) {
    my ( $run, $known ) = $arg->@{qw(run known)};
    my $member = { %PLAIN, %{ $arg->{member} || {} } };
    my $cells  = _cells( $run, $known, $member );
    my $truth  = _verdicts( $known, $cells, $arg->{coverage} );
    my @found  = _changes( $run, _deviations( { $arg->%*, reference => undef } ), 'I7', 'the truth' );
    for my $key ( keys $cells->%* ) {
        my ( $want, $killer ) = $truth->{$key}->@*;
        my $id = $cells->{$key}{id};
        next if $want ne 'Killed' || $run->{status}{$id} ne 'Killed';
        my $by = $run->{by}{$id};
        if ( !defined $by ) {
            push @found, 'I7 a killed mutant names no test';
            next;
        }
        my $kills = defined $member->{test} ? $by eq $member->{test} : $killer->{$by};
        push @found, 'I7 the killing test passes in truth' if !$kills;
    }
    return _unique(@found);
}

# One line for each status that the run gives in place of the statuses of the source.
sub _changes ( $run, $deviations, $invariant, $source ) {
    my %from;
    $from{ $run->{status}{ $_->{id} } }{ $_->{want} } = 1 for grep { defined $_->{id} } $deviations->@*;
    return map { "$invariant the run gives $_ where $source gives " . join ' and ', sort keys $from{$_}->%* }
      sort keys %from;
}

# The mutants of a member whose status differs from the one the reference gives, each with both statuses.
# The reference is another member of the same run, or the truth when the run holds one member alone.
sub _deviations ($arg) {
    my ( $run, $known ) = $arg->@{qw(run known)};
    my $member = { %PLAIN, %{ $arg->{member} || {} } };
    my $cells  = _cells( $run, $known, $member );
    my %want;
    if ( $arg->{reference} ) {
        my $reference = _cells( $run, $known, $arg->{reference} );
        %want = map { $_ => $run->{status}{ $reference->{$_}{id} } } keys $reference->%*;
    }
    else {
        my $truth = _verdicts( $known, $cells, $arg->{coverage} );
        %want = map { $_ => $truth->{$_}[0] } keys $truth->%*;
    }
    return [
        map  { { want => $want{$_}, id => $cells->{$_} ? $cells->{$_}{id} : undef } }
        grep { !$cells->{$_} || _differs( $want{$_}, $run->{status}{ $cells->{$_}{id} } ) } sort keys %want
    ];
}

# The verdicts of a loading style equal those of the reference style in the same run.
sub _same_under_styles ($arg) {
    my $run        = $arg->{run};
    my $deviations = _deviations($arg);
    my @absent     = grep { !defined $_->{id} } $deviations->@*;
    return 'I8 the run lists no mutant in the cells of the style'
      if @absent && !%{ _cells( $run, $arg->{known}, $arg->{member} ) };
    return (
        ( @absent ? 'I8 the style lacks a mutant of the reference style' : () ),
        _changes( $run, $deviations, 'I8', 'the reference style' ),
    );
}

# A member whose verdicts deviate says so: a warning names its test or its file, or each such mutant has no verdict and a reason.
sub _reported ($arg) {
    my ( $run, $member ) = $arg->@{qw(run member)};
    my $deviations = _deviations($arg);
    return if !$deviations->@*;
    return if grep { index( $_, $member->{test} ) >= 0 || index( $_, $member->{target} ) >= 0 } $run->{warnings}->@*;
    my @absent = grep { !defined $_->{id} } $deviations->@*;
    my @silent = grep { $MEASURED{ $run->{status}{$_} } || !defined $run->{reason}{$_} || !length $run->{reason}{$_} }
      map { defined $_->{id} ? $_->{id} : () } $deviations->@*;
    return @absent || @silent ? 'I6 the verdicts deviate without a warning or a reason' : ();
}

1;
