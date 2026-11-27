package Test::Mutation::Report::GitHub;
use v5.36;
use Encode                 ();
use Types::Common::Numeric qw(PositiveOrZeroInt);
use Types::Standard        qw(ArrayRef InstanceOf Maybe Num Str);
use Type::Params           qw(signature_for);
use Test::Mutation::Status;
use Test::Mutation::Report::Results;

our $VERSION = '0.001';

sub _message ($text) {
    return $text =~ s/%/%25/gr =~ s/\r/%0D/gr =~ s/\n/%0A/gr;
}

sub _property ($text) {
    return _message($text) =~ s/:/%3A/gr =~ s/,/%2C/gr;
}

signature_for annotations => ( positional => [ InstanceOf ['Test::Mutation::Result'] ], returns => Str );

sub annotations ($result) {
    my @lines;
    my %emitted;
    for my $entry ( $result->entries->@* ) {
        my $status = Test::Mutation::Status::of( $entry->{status} );
        my $level  = $status->annotation or next;
        next if ++$emitted{$level} > 10;
        my $title  = $status->heading;
        my $mutant = $entry->{mutant};
        push @lines, sprintf '::%s file=%s,line=%d,col=%d,endLine=%d,endColumn=%d,title=%s::%s (%s)',
          $level, _property( $mutant->path ), $mutant->from->@*, $mutant->to->@*, _property($title),
          _message( $mutant->description ), $mutant->id;
    }
    return join q{}, map { "$_\n" } @lines;
}

signature_for summary => (
    positional => [
        InstanceOf ['Test::Mutation::Result'],
        Maybe [Num],
        { default => undef },
        ArrayRef [Str],
        { default => sub { [] } },
        PositiveOrZeroInt, { default => 0 }
    ],
    returns => Str,
);

sub summary ( $result, $floor, $reports, $used ) {
    my $budget = 1024 * 1024 - $used;
    my $tally  = $result->tally;
    my $counts = $tally->{counts};
    my $score  = 'Score: none';
    if ( defined $tally->{score} ) {
        my $noun = $tally->{valid} == 1 ? 'valid mutant' : 'valid mutants';
        $score = sprintf 'Score: **%.1f%%** (%d of %d %s)', $tally->{score}, $counts->{Killed}, $tally->{valid}, $noun;
    }
    my @rows = Test::Mutation::Status::rows()->@*;
    my ( $scope, $undetected ) = Test::Mutation::Report::Results::overview($result)->@*;
    my $details =
      @$reports
      ? 'Detailed reports: ' . join( ', ', map { _cell($_) } @$reports )
      : 'Detailed report: run mutation run --format json';
    my $head = join "\n", '## Mutation testing', q{}, _cell($scope), $undetected,
      Test::Mutation::Report::Results::decision( $result, $floor )->@*, q{}, $score, q{},
      _row( map { ucfirst $_->word } @rows ), _row( ('---') x @rows ), _row( map { $counts->{ $_->name } } @rows ), q{};
    my $tail      = "\n$details\n\n" . Test::Mutation::Report::Results::next_step( $result, $floor ) . "\n";
    my $remaining = $budget - length Encode::encode( 'UTF-8', $head . $tail );
    if ( $remaining < 0 ) {
        my $brief = "$undetected\n$score\n";
        return length( Encode::encode( 'UTF-8', $brief ) ) <= $budget ? $brief : q{};
    }
    my $examples = q{};
    my $shown    = 0;
    for my $entry ( $result->entries->@* ) {
        next unless Test::Mutation::Status::of( $entry->{status} )->role eq 'undetected';
        my $mutant = $entry->{mutant};
        my $row =
          _row( $mutant->id, join( q{:}, $mutant->path, $mutant->from->@* ), $mutant->description, $entry->{status} )
          . "\n";
        $row =
            "\n### Undetected changes\n\n"
          . _row(qw(ID Location Change Status)) . "\n"
          . _row( ('---') x 4 ) . "\n"
          . $row
          unless $shown;
        my $size = length Encode::encode( 'UTF-8', $row );
        next if $size > $remaining;
        $examples .= $row;
        $remaining -= $size;
        last if ++$shown == 5;
    }
    return $head . $examples . $tail;
}

sub _row (@cells) {
    return '| ' . join( ' | ', map { _cell($_) } @cells ) . ' |';
}

sub _cell ($text) {
    return $text =~ s/([&<>|\x60*_\[\]\\\r\n])/sprintf('&#%d;', ord $1)/ger;
}

1;

__END__

=head1 NAME

Test::Mutation::Report::GitHub - render a result for GitHub Actions

=head1 SYNOPSIS

    print Test::Mutation::Report::GitHub::annotations($result);
    my $markdown = Test::Mutation::Report::GitHub::summary($result);

=head1 FUNCTIONS

=head2 annotations

Returns up to ten workflow commands per annotation level from L<Test::Mutation::Status>.
GitHub shows each command as an annotation on the mutated lines, titled with the heading of the status.

=head2 summary

Returns the measured scope, score, gate, and up to five undetected changes as Markdown.
The optional report paths point to the full results.
The last argument counts the bytes already present in the step summary.

=cut
