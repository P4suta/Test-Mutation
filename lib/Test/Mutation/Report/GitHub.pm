package Test::Mutation::Report::GitHub;
use v5.36;
use Types::Standard qw(InstanceOf Maybe Num Str);
use Type::Params    qw(signature_for);
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

signature_for summary =>
  ( positional => [ InstanceOf ['Test::Mutation::Result'], Maybe [Num], { default => undef } ], returns => Str );

sub summary ( $result, $floor ) {
    my $tally  = $result->tally;
    my $counts = $tally->{counts};
    my $score  = 'Score: none';
    if ( defined $tally->{score} ) {
        my $noun = $tally->{valid} == 1 ? 'valid mutant' : 'valid mutants';
        $score = sprintf 'Score: **%.1f%%** (%d of %d %s)', $tally->{score}, $counts->{Killed}, $tally->{valid}, $noun;
    }
    my @rows  = Test::Mutation::Status::rows()->@*;
    my @lines = (
        '## Mutation testing',
        q{},
        Test::Mutation::Report::Results::decision( $result, $floor )->@*,
        q{},
        $score,
        q{},
        _row( map { ucfirst $_->word } @rows ),
        _row( ('---') x @rows ),
        _row( map { $counts->{ $_->name } } @rows )
    );
    my $files = Test::Mutation::Report::Results::files($result);
    if (@$files) {
        my $columns = Test::Mutation::Report::Results::columns();
        push @lines, q{}, '### Files', q{}, _row(@$columns), _row( ('---') x @$columns ),
          map { _row( $_->{cells}->@* ) } @$files;
    }
    if ( $result->entries->@* ) {
        push @lines, q{}, '### Mutants', q{}, _row(qw(ID Location Mutator Description Status)), _row( ('---') x 5 );
        for my $file (@$files) {
            for my $entry ( $file->{entries}->@* ) {
                my $mutant = $entry->{mutant};
                push @lines,
                  _row( $mutant->id, join( q{:}, $file->{path}, $mutant->from->@* ),
                    $mutant->mutator, $mutant->description, $entry->{status} );
            }
        }
    }
    push @lines, q{}, Test::Mutation::Report::Results::next_step( $result, $floor );
    return join q{}, map { "$_\n" } @lines;
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

Returns the outcome, optional gate, file scores and every measured change as Markdown for the job summary.

=cut
