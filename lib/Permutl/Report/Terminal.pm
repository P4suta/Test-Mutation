package Permutl::Report::Terminal;
use v5.36;
use Types::Standard qw(Bool InstanceOf Num Optional Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my @COUNTED = (
    [ Killed       => 'killed' ],
    [ Survived     => 'survived' ],
    [ NoCoverage   => 'no coverage' ],
    [ Timeout      => 'timeout' ],
    [ CompileError => 'compile error' ],
    [ RuntimeError => 'runtime error' ],
    [ Ignored      => 'ignored' ],
    [ Pending      => 'pending' ],
);
my @SECTIONS = (
    [ Survived     => 'Survived' ],
    [ NoCoverage   => 'No coverage' ],
    [ Timeout      => 'Timeout' ],
    [ RuntimeError => 'Runtime error' ],
);
my $LISTED_TESTS = 3;

signature_for render => (
    head    => [ InstanceOf ['Permutl::Result'] ],
    named   => [ color => Bool, high => Optional [Num], low => Optional [Num] ],
    returns => Str,
);

sub render ( $result, $arg ) {
    my @blocks;
    if ( $result->baseline_failures->@* ) {
        push @blocks, _baseline($result);
    }
    else {
        push @blocks, _summary( $result, $arg );
        push @blocks, map { _section( $result, $_->@* ) } @SECTIONS;
    }
    my @notes = (
        ( map { "warning: $_" } $result->warnings->@* ),
        ( map { "skipped $_->{path}: $_->{problem}" } $result->problems->@* ),
    );
    push @blocks, join "\n", @notes if @notes;
    return join( "\n\n", grep { length } @blocks ) . "\n";
}

sub _plural ( $count, $noun ) {
    return $count == 1 ? "$count $noun" : "$count ${noun}s";
}

sub _summary ( $result, $arg ) {
    my $tally  = $result->tally;
    my $counts = $tally->{counts};
    my @parts  = map { "$counts->{ $_->[0] } $_->[1]" } grep { $counts->{ $_->[0] } } @COUNTED;
    my @lines  = ( _plural( $tally->{total}, 'mutant' ) . ( @parts ? ': ' . join ', ', @parts : q{} ) );

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
    push @lines, join ', ', _plural( scalar $result->tests->@*, 'test' ), _plural( $result->jobs, 'job' ), $seconds;
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
    return q{} if !@entries;
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
    push @lines, "    $entry->{reason}" if defined $entry->{reason};
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
        push @lines, "  $failure->{test}";
        push @lines, map { "    $_" } grep { length } split /\n/, $failure->{output} . $failure->{errors};
    }
    return join "\n", @lines;
}

1;

__END__

=head1 NAME

Permutl::Report::Terminal - render a result as text for a terminal

=head1 SYNOPSIS

    print Permutl::Report::Terminal::render( $result, color => -t STDOUT );

=head1 FUNCTIONS

=head2 render

Returns the report as one string.
The summary counts every status, states the score, and names the number of tests, jobs, and seconds.
Mutants that survived, had no coverage, timed out, or ended in a runtime error follow, each with its place, its change, and the tests that reached it.
When the unmodified run fails, the report shows the failing tests with their output in place of the summary.
C<color> wraps the score in an escape sequence chosen by the C<high> and C<low> percentages, 80 and 60 by default.

=cut
