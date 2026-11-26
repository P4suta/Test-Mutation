package Test::Mutation::Report::Terminal;
use v5.36;
use Types::Standard qw(Bool InstanceOf Num Optional Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Status;

our $VERSION = '0.001';

my $LISTED_TESTS = 3;

signature_for render => (
    head    => [ InstanceOf ['Test::Mutation::Result'] ],
    named   => [ color => Bool, high => Optional [Num], low => Optional [Num] ],
    returns => Str,
);

sub render ( $result, $arg ) {
    my @blocks =
      $result->baseline_failures->@*
      ? _baseline($result)
      : (
        _summary( $result, $arg ),
        map { _section( $result, $_->name, $_->heading ) }
          grep { defined $_->heading } Test::Mutation::Status::rows()->@*
      );
    my @notes = (
        ( map { "warning: $_" } $result->warnings->@* ),
        ( map { "skipped $_->{path}: $_->{problem}" } $result->problems->@* ),
    );
    push @blocks, join "\n", @notes if @notes;
    return join( "\n\n", @blocks ) . "\n";
}

sub _plural ( $count, $noun ) {
    return $count == 1 ? "$count $noun" : "$count ${noun}s";
}

sub _summary ( $result, $arg ) {
    my $tally  = $result->tally;
    my $counts = $tally->{counts};
    my @parts =
      map { "$counts->{ $_->name } " . $_->word } grep { $counts->{ $_->name } } Test::Mutation::Status::rows()->@*;
    my @lines = ( _plural( $tally->{total}, 'mutant' ) . ( @parts ? ': ' . join ', ', @parts : q{} ) );
    if ( defined $result->shard && $result->inventory ) {
        my ( $part, $of ) = split m{/}, $result->shard;
        push @lines, "Part $part of $of of a run with " . _plural( $result->inventory->{mutants}, 'mutant' ) . q{.};
    }

    my $score = 'Score: none (no valid mutant)';
    if ( defined $tally->{score} ) {
        $score = sprintf 'Score: %.1f%% (%d of %s)', $tally->{score}, $counts->{Killed},
          _plural( $tally->{valid}, 'valid mutant' );
        $score = _colored( $score, $tally->{score}, $arg ) if $arg->color;
    }
    push @lines, $score;
    push @lines, 'Timeouts are inconclusive and count toward neither side.'     if $counts->{Timeout};
    push @lines, 'The run was interrupted by SIG' . $result->interrupted . q{.} if defined $result->interrupted;

    my $seconds = sprintf '%.1f s', $result->finished - $result->started;
    my @facts   = ( _plural( scalar $result->tests->@*, 'test' ), _plural( $result->jobs, 'job' ), $seconds );
    push @facts, _plural( $result->reused, 'result' ) . ' from the cache' if $result->reused;
    push @lines, join ', ', @facts;
    return join "\n", @lines;
}

sub _colored ( $text, $score, $arg ) {
    my $high = $arg->has_high  ? $arg->high : 80;
    my $low  = $arg->has_low   ? $arg->low  : 60;
    my $code = $score >= $high ? 32         : $score >= $low ? 33 : 31;
    return "\e[${code}m$text\e[0m";
}

sub _section ( $result, $status, $title ) {
    my @entries = grep { $_->{status} eq $status } $result->entries->@*;
    return if !@entries;
    return join "\n", sprintf( '%s (%d)', $title, scalar @entries ), map { _entry( $result, $_ ) } @entries;
}

sub _entry ( $result, $entry ) {
    my $mutant = $entry->{mutant};
    my @lines = ( sprintf '  %s:%d:%d  %s  [%s]', $mutant->path, $mutant->from->@*, $mutant->description, $mutant->id );
    push @lines, map { "    $_" } _change( $result->sources->{ $mutant->path }, $mutant );

    my @tests = $entry->{covered_by}->@*;
    my $more  = @tests > $LISTED_TESTS ? sprintf ' and %d more', @tests - $LISTED_TESTS : q{};
    splice @tests, $LISTED_TESTS if $more;
    push @lines, '    reached by ' . ( @tests ? join( ', ', @tests ) . $more : 'no test' );
    push @lines, "    $entry->{reason}" if $entry->{status} eq 'CompileError';
    push @lines, "    $entry->{detail}" if defined $entry->{detail};
    return @lines;
}

sub _change ( $text, $mutant ) {
    return if !defined $text;
    my $mutated = $text;
    substr $mutated, $mutant->start, $mutant->end - $mutant->start, $mutant->replacement;
    my $index    = $mutant->from->[0] - 1;
    my $original = ( split /\n/, $text,    -1 )[$index];
    my $changed  = ( split /\n/, $mutated, -1 )[$index];
    my $ellipsis = $mutant->original =~ /\n/ ? ' ...' : q{};
    return ( "- $original$ellipsis", "+ $changed" );
}

sub _baseline ($result) {
    my @lines = ('The unmodified run fails, so no mutant ran.');
    for my $failure ( $result->baseline_failures->@* ) {
        push @lines, "  $failure->{test}" . ( defined $failure->{reason} ? " ($failure->{reason})" : q{} );

        # A passing assertion and the plan of a subtest explain no failure, and a test suite has hundreds of them.
        push @lines, map { "    $_" } grep { length && !/\A\s*ok\b/ && !/\A\s+\d+[.][.]\d+/ } split /\n/,
          $failure->{output} . $failure->{errors};
    }
    push @lines, 'The tests ran in a copy of the project, which holds no .git directory.',
      '--in-place runs them in the project itself.'
      if $result->in_copies;
    return join "\n", @lines;
}

1;

__END__

=head1 NAME

Test::Mutation::Report::Terminal - render a result as text for a terminal

=head1 SYNOPSIS

    print Test::Mutation::Report::Terminal::render( $result, color => -t STDOUT );

=head1 FUNCTIONS

=head2 render

Returns the report as one string.
The summary counts every status with the word of L<Test::Mutation::Status>, states the score, and names the number of tests, jobs, and seconds.
A section follows for each status with a heading in the catalog: the mutants that survived, had no coverage, timed out, or have no verdict.
Each mutant shows its place, its change, the tests that reached it, and the sentence about its case.
When the unmodified run fails, the report shows the failing tests with their output in place of the summary.
A test that a limit ended names the reason of the limit beside its name.
The output leaves out the passing assertions.
C<color> wraps the score in an escape sequence chosen by the C<high> and C<low> percentages, 80 and 60 by default.

=cut
