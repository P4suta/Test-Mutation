package Test::Mutation::Report::Terminal;
use v5.36;
use Types::Standard qw(Bool InstanceOf Maybe Num Optional Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Status;
use Test::Mutation::Report::Results;

our $VERSION = '0.001';

my $LISTED_TESTS = 3;

signature_for render => (
    head    => [ InstanceOf ['Test::Mutation::Result'] ],
    named   => [ color => Bool, high => Optional [Num], low => Optional [Num], floor => Optional [ Maybe [Num] ] ],
    returns => Str,
);

sub render ( $result, $arg ) {
    my $files  = Test::Mutation::Report::Results::files($result);
    my @blocks = (
        join( "\n",
            Test::Mutation::Report::Results::overview($result)->@*,
            Test::Mutation::Report::Results::decision( $result, $arg->floor )->@* )
    );
    if ( $result->baseline_failures->@* ) {
        push @blocks, _baseline($result);
    }
    else {
        push @blocks, _summary( $result, $arg );
        push @blocks, map { _section( $result, $_ ) } @$files;
        if (@$files) {
            push @blocks, join "\n", map { join q{  }, $_->@* } Test::Mutation::Report::Results::columns(),
              map { $_->{cells} } @$files;
        }
    }
    my @notes = (
        ( map { "warning: $_" } $result->warnings->@* ),
        ( map { "skipped $_->{path}: $_->{problem}" } $result->problems->@* ),
    );
    push @blocks, join "\n", @notes if @notes;
    push @blocks, Test::Mutation::Report::Results::next_step( $result, $arg->floor );
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

sub _section ( $result, $file ) {
    my @listed = grep { defined Test::Mutation::Status::of( $_->{status} )->heading } $file->{entries}->@*;
    return if !@listed;
    return join "\n", $file->{path}, map { _entry( $result, $_ ) } @listed;
}

sub _entry ( $result, $entry ) {
    my $mutant = $entry->{mutant};
    my @lines  = ( '  ' . Test::Mutation::Report::Results::heading($mutant) . "  [$entry->{status}]" );
    push @lines, map { "    $_" } _change( $result->sources->{ $mutant->path }, $mutant );

    my @tests = $entry->{covered_by}->@*;
    my $more  = @tests > $LISTED_TESTS ? sprintf ' and %d more', @tests - $LISTED_TESTS : q{};
    splice @tests, $LISTED_TESTS if $more;
    push @lines, '    reached by ' . ( @tests ? join( ', ', @tests ) . $more : 'no test' );
    push @lines, "    $entry->{reason}"                     if $entry->{status} eq 'CompileError';
    push @lines, "    $entry->{detail}"                     if defined $entry->{detail};
    push @lines, '    Exercise the mutated line in a test.' if $entry->{status} eq 'NoCoverage';
    push @lines, '    Check that the original test gives the same result on repeated runs.'
      if $entry->{status} eq 'NoVerdict' && $entry->{reason} =~ /\A(?:unstable|conflicting)-test\z/;
    push @lines, '    Recheck: mutation run --mutant ' . $mutant->id
      if Test::Mutation::Status::of( $entry->{status} )->role eq 'undetected' || $entry->{status} eq 'NoVerdict';
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
The file table counts all outcomes, and the details group changes that need attention by source path.
Each mutant shows its place, its change, the tests that reached it, and the sentence about its case.
When the unmodified run fails, the report shows the failing tests with their output in place of the summary.
A test that a limit ended names the reason of the limit beside its name.
The output leaves out the passing assertions.
C<color> wraps the score in an escape sequence chosen by the C<high> and C<low> percentages, 80 and 60 by default.

=cut
