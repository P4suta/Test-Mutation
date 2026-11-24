package Discovery::Check;
use v5.36;
use Discovery::Engine;
use Discovery::Known;
use Discovery::Reader;

# Every invariant and every relation of the engine, each as a function from observations to the text of its violations.
# The text names a kind of violation and no mutant, path of a run, or count, so a finding reads the same on every run.

my %DECIDED    = map { $_ => 1 } qw(Killed Survived);
my %MEASURED   = map { $_ => 1 } qw(Killed Survived NoCoverage);
my %UNDETECTED = map { $_ => 1 } qw(Survived NoCoverage);
my %PLAIN      = ( target => 'lib/Known.pm', shift => 0 );

my %CHECK = (
    'completes'  => \&_completes,
    'I2'         => \&_no_process,
    'I3'         => \&_no_leftover,
    'I4'         => \&_unchanged,
    'I5'         => \&_reasons,
    'I6'         => \&_reported,
    'I7'         => \&_truth,
    'I8'         => \&_same_under_styles,
    'tap'        => \&_tap,
    'tap-prefix' => \&_tap_prefix,
    'jobs'       => \&_jobs,
    'in-place'   => \&_in_place,
    'coverage'   => \&_coverage,
    'shard'      => \&_shard,
    'since'      => \&_since,
    'single'     => \&_single,
    'cache'      => \&_cache,
    'prove'      => \&_prove,
);

# The ways a test process ends after a stream, apart from status 0: each one fails the test under prove.
my @FAILING_ENDS = ( [ 'exit=1', 1, 0 ], [ 'exit=255', 255, 0 ], [ 'exit=signal', 0, 15 ] );

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
    my @found  = _changes( $run, _deviations( { $arg->%*, reference => undef } ), 'I7 the run', 'the truth' );
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
sub _changes ( $run, $deviations, $subject, $source ) {
    my %from;
    $from{ $run->{status}{ $_->{id} } }{ $_->{want} } = 1 for grep { defined $_->{id} } $deviations->@*;
    return map { "$subject gives $_ where $source gives " . join ' and ', sort keys $from{$_}->%* } sort keys %from;
}

# The statuses of two runs of one project, where `allowed` tells which pairs the relation of the two accepts.
# A relation between whole runs also requires the mutants of the earlier run in the later one.
sub _between ( $earlier, $later, $names, $allowed, $whole = 1 ) {
    my ( %from, @found );
    for my $id ( keys $later->{status}->%* ) {
        my ( $was, $is ) = ( $earlier->{status}{$id}, $later->{status}{$id} );
        if ( !defined $was ) {
            push @found, "$names->[1] holds a mutant that $names->[0] lacks";
            next;
        }
        $from{$is}{$was} = 1 if !$allowed->( $was, $is );
    }
    push @found, "$names->[1] lacks a mutant of $names->[0]"
      if $whole && grep { !exists $later->{status}{$_} } keys $earlier->{status}->%*;
    push @found,
      map { "$names->[1] gives $_ where $names->[0] gives " . join ' and ', sort keys $from{$_}->%* } sort keys %from;
    return _unique(@found);
}

sub _timed_out (@statuses) {
    return scalar grep { $_ eq 'Timeout' } @statuses;
}

my %SIDE = ( Killed => 'detected', Survived => 'undetected', NoCoverage => 'undetected' );

# One job and several jobs give the same detected and the same undetected mutants, apart from timeouts.
sub _jobs ($arg) {
    return _between(
        $arg->@{qw(run other)},
        [ 'the run with one job', 'the run with more jobs' ],
        sub ( $was, $is ) {
            return _timed_out( $was, $is ) || ( $SIDE{$was} || 'neither' ) eq ( $SIDE{$is} || 'neither' );
        }
    );
}

# A run in the project gives the statuses of a run in copies, or no verdict.
sub _in_place ($arg) {
    return _between(
        $arg->@{qw(run other)},
        [ 'the run in copies', 'the run in the project' ],
        sub ( $was, $is ) { return $was eq $is || $is eq 'NoVerdict' }
    );
}

# File coverage runs more tests for a mutant, so it may turn a mutant without coverage into a survivor and no more.
sub _coverage ($arg) {
    return _between(
        $arg->@{qw(run other)},
        [ 'the run with line coverage', 'the run with file coverage' ],
        sub ( $was, $is ) { return $was eq $is || ( $was eq 'NoCoverage' && $is eq 'Survived' ) }
    );
}

sub _shard ($arg) {
    return _between(
        $arg->@{qw(run other)},
        [ 'the whole run', 'the merge of the parts' ],
        sub ( $was, $is ) { return $was eq $is }
    );
}

sub _since ($arg) {
    return _between(
        $arg->@{qw(run other)},
        [ 'the whole run', 'the run on the changed lines' ],
        sub ( $was, $is ) { return $was eq $is }, 0
    );
}

sub _single ($arg) {
    return _unique(
        map {
            _between(
                $arg->{run}, $_,
                [ 'the whole run', 'the run of one mutant' ],
                sub ( $was, $is ) { return $was eq $is || _timed_out( $was, $is ) }, 0
            )
        } $arg->{others}->@*
    );
}

my @KEPT = qw(Killed Survived CompileError Ignored);

# A run with the cache gives the truth of the files as they are, whatever an earlier run stored.
# `reuse` says what the run may take from the cache: `all` on unchanged inputs, `none` after a change that every result depends on.
# `stored` lists the mutants that the cache holds after the run.
sub _cache ($arg) {
    my $run = $arg->{run};
    my @found =
      _changes( $run, _deviations( { $arg->%*, reference => undef } ), 'the run with the cache', 'the truth' );
    my %count;
    $count{$_}++ for values $run->{status}->%*;
    my $kept = 0;
    $kept += $count{$_} || 0 for @KEPT;
    my $reuse = defined $arg->{reuse} ? $arg->{reuse} : 'any';
    push @found, 'the run reuses a result that depends on the changed input' if $reuse eq 'none' && $run->{reused} > 0;
    push @found,
        $run->{reused} < $kept                               ? 'the run measures again a result that the cache holds'
      : $run->{reused} < $kept + ( $count{NoCoverage} || 0 ) ? 'the run measures again a mutant without coverage'
      : ()
      if $reuse eq 'all';
    push @found, 'the cache keeps the record of a mutant that is gone'
      if grep { !exists $run->{mutants}{$_} } @{ $arg->{stored} || [] };
    return _unique(@found);
}

# prove runs the tests on the files with one mutant in place, and `verdicts` holds its answer for each test.
# The test that detects a mutant fails there, and no test fails on a mutant that the run calls undetected.
sub _prove ($arg) {
    my ( $run, $verdicts ) = $arg->@{qw(run verdicts)};
    my @found;
    for my $id ( keys $verdicts->%* ) {
        my $status  = $run->{status}{$id};
        my $under   = $verdicts->{$id};
        my @failing = grep { $under->{$_} ne 'pass' } keys $under->%*;
        if ( $status eq 'Killed' ) {
            my $by = $run->{by}{$id};
            push @found, 'prove passes the test that detects a mutant in the run'
              if defined $by && defined $under->{$by} && $under->{$by} eq 'pass';
        }
        elsif ( $UNDETECTED{$status} && @failing ) {
            push @found, "prove fails a test on a mutant that the run gives as $status";
        }
    }
    return _unique(@found);
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
        _changes( $run, $deviations, 'I8 the run', 'the reference style' ),
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

# Every way to keep some and not all of the parts, in their order.
sub _fewer (@parts) {
    my @subsets;
    for my $mask ( 1 .. 2**@parts - 2 ) {
        push @subsets, join q{ }, map { $parts[$_] } grep { $mask & 2**$_ } 0 .. $#parts;
    }
    return @subsets;
}

# A stream with several choices adds nothing when fewer of its choices show the same disagreement.
sub _smallest ( $cases, $kind ) {
    my @found;
    for my $case ( grep { defined $kind->{ $_->{label} } } $cases->@* ) {
        my $text = $kind->{ $case->{label} };
        next if grep { defined $kind->{$_} && $kind->{$_} eq $text } _fewer( $case->{parts}->@* );
        push @found, "$case->{label}: $text";
    }
    return @found;
}

# The reader of the tool gives the verdict of prove on every stream, under every way a process ends.
# `reader` is the adapter of the reader, and each of `cases` is a stream with the choices that make it.
sub _tap ($arg) {
    my ( $reader, $cases ) = $arg->@{qw(reader cases)};
    my ( %kind, @found );
    for my $case ( $cases->@* ) {
        my $text   = $case->{text};
        my $passes = $reader->passes( $text, 0, 0 );
        $kind{ $case->{label} } =
          $passes
          ? 'the reader passes a stream that TAP::Parser fails'
          : 'the reader fails a stream that TAP::Parser passes'
          if $passes != Discovery::Reader::oracle( $text, 0, 0 );
        push @found, map { "$_->[0]: the reader passes a test that prove fails" }
          grep { $reader->passes( $text, $_->@[ 1, 2 ] ) } @FAILING_ENDS;
    }
    return _unique( @found, _smallest( $cases, \%kind ) );
}

# The reader calls a stream failed after some of its lines, and the whole stream then fails under prove.
# An early stop on a stream that passes would count a mutant as detected that the test accepts.
sub _tap_prefix ($arg) {
    my ( $reader, $cases ) = $arg->@{qw(reader cases)};
    my %kind;
    for my $case ( $cases->@* ) {
        next if !Discovery::Reader::oracle( $case->{text}, 0, 0 );
        my $prefix = q{};
        for my $line ( $case->{text} =~ /([^\n]*\n)/g ) {
            $prefix .= $line;
            next if !$reader->stops($prefix);
            $kind{ $case->{label} } = 'the reader stops early on a stream that TAP::Parser passes';
            last;
        }
    }
    return _unique( _smallest( $cases, \%kind ) );
}

1;
