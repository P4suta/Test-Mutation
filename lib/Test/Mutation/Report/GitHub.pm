package Test::Mutation::Report::GitHub;
use v5.36;
use Types::Standard qw(InstanceOf Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my %ANNOTATION = (
    Survived   => [ 'warning', 'Survived mutant' ],
    NoCoverage => [ 'warning', 'Mutant without coverage' ],
    Timeout    => [ 'notice',  'Mutant timed out' ],
);

sub _message ($text) {
    return $text =~ s/%/%25/gr =~ s/\r/%0D/gr =~ s/\n/%0A/gr;
}

sub _property ($text) {
    return _message($text) =~ s/:/%3A/gr =~ s/,/%2C/gr;
}

signature_for annotations => ( positional => [ InstanceOf ['Test::Mutation::Result'] ], returns => Str );

sub annotations ($result) {
    my @lines;
    for my $entry ( $result->entries->@* ) {
        my $annotation = $ANNOTATION{ $entry->{status} } or next;
        my ( $level, $title ) = $annotation->@*;
        my $mutant = $entry->{mutant};
        push @lines, sprintf '::%s file=%s,line=%d,col=%d,endLine=%d,endColumn=%d,title=%s::%s (%s)',
          $level, _property( $mutant->path ), $mutant->from->@*, $mutant->to->@*, _property($title),
          _message( $mutant->description ), $mutant->id;
    }
    return join q{}, map { "$_\n" } @lines;
}

signature_for summary => ( positional => [ InstanceOf ['Test::Mutation::Result'] ], returns => Str );

sub summary ($result) {
    my $tally  = $result->tally;
    my $counts = $tally->{counts};
    my $score  = 'Score: none';
    if ( defined $tally->{score} ) {
        my $noun = $tally->{valid} == 1 ? 'valid mutant' : 'valid mutants';
        $score = sprintf 'Score: **%.1f%%** (%d of %d %s)', $tally->{score}, $counts->{Killed}, $tally->{valid}, $noun;
    }
    return join q{}, map { "$_\n" } '## Mutation testing', q{}, $score, q{},
      '| Killed | Survived | No coverage | Timeout |',
      '| --- | --- | --- | --- |',
      sprintf( '| %d | %d | %d | %d |', $counts->@{qw(Killed Survived NoCoverage Timeout)} );
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

Returns one workflow command for each mutant that survived, had no coverage, or timed out.
GitHub shows each command as an annotation on the mutated lines.

=head2 summary

Returns Markdown for the job summary: the score and a table of counts.

=cut
