package Test::Mutation::Outcome;
use v5.36;
use Types::Standard qw(Dict Enum InstanceOf Maybe Num Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Exit;
use Test::Mutation::Message;
use Test::Mutation::Status;

our $VERSION = '0.001';

my $DECISION = Dict [
    name       => Enum [qw(interrupted baseline-failed invalid-mutant inconclusive measured nothing)],
    exit       => InstanceOf ['Test::Mutation::Exit'],
    diagnostic => Maybe [Str],
];

signature_for of => ( positional => [ InstanceOf ['Test::Mutation::Result'], Maybe [Num] ], returns => $DECISION );

sub of ( $result, $floor ) {
    my $signal = $result->interrupted;
    return _decision( 'interrupted', $signal, Test::Mutation::Message::text_of( 'interrupted', signal => $signal ) )
      if defined $signal;
    my $failed = scalar $result->baseline_failures->@*;
    return _decision( 'baseline-failed', 'baseline-failed',
        Test::Mutation::Message::text_of( 'baseline-failed', failed => $failed ) )
      if $failed;
    if ( my $invalid = $result->invalid_entry ) {
        my $mutant = $invalid->{mutant};
        return _decision( 'invalid-mutant', 'internal',
            Test::Mutation::Message::text_of( 'invalid-mutant', id => $mutant->id, path => $mutant->path ) );
    }

    my $tally      = $result->tally;
    my $score      = $tally->{score};
    my $counts     = $tally->{counts};
    my $incomplete = grep { $_->incomplete && $counts->{ $_->name } } Test::Mutation::Status::rows()->@*;
    return _decision( 'inconclusive', 'inconclusive', Test::Mutation::Message::text_of('inconclusive') )
      if $result->cache_mismatch
      || $result->problems->@*
      || $incomplete
      || !defined $score && $counts->{Timeout};
    my $gated = defined $floor && !defined $result->shard;
    if ( !defined $score ) {
        return _decision( 'nothing', 'inconclusive', Test::Mutation::Message::text_of('inconclusive') )
          if $gated && !keys $result->selection->%*;
        return _decision( 'nothing', 'success' );
    }
    return _decision( 'measured', 'below-gate',
        Test::Mutation::Message::text_of( 'below-gate', score => sprintf( '%.1f', $score ), gate => $floor ) )
      if $gated && $score < $floor;
    return _decision( 'measured', 'success' );
}

sub _decision ( $name, $exit, $diagnostic = undef ) {
    return {
        name       => $name,
        exit       => Test::Mutation::Exit::row($exit),
        diagnostic => $diagnostic
    };
}

1;

__END__

=head1 NAME

Test::Mutation::Outcome - decide a measurement from its results and score threshold

=head1 FUNCTIONS

=head2 of

Takes a result and an optional minimum score.
Returns the outcome name, its exit catalog entry and an optional diagnostic.
An interruption or failing original test takes priority over the mutant verdicts.
A shard defers its score threshold until the parts have been merged.
A whole project with no score fails a requested threshold, while an empty narrowed selection succeeds.

=cut
