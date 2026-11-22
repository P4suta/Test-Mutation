package Permutl::Score;
use v5.36;
use Types::Standard qw(ArrayRef Dict HashRef Int Maybe Num Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my @STATUSES = qw(Killed Survived NoCoverage Timeout CompileError RuntimeError Ignored Pending);

signature_for tally => (
    positional => [ ArrayRef [Str] ],
    returns    => Dict [ counts => HashRef [Int], total => Int, valid => Int, score => Maybe [Num] ],
);

sub tally ($statuses) {
    my %counts = map { $_ => 0 } @STATUSES;
    $counts{$_}++ for $statuses->@*;
    my $killed = $counts{Killed};
    my $valid  = $killed + $counts{Survived} + $counts{NoCoverage};
    return {
        counts => \%counts,
        total  => scalar $statuses->@*,
        valid  => $valid,
        score  => $valid ? 100 * $killed / $valid : undef,
    };
}

1;

__END__

=head1 NAME

Permutl::Score - count statuses and compute the mutation score

=head1 SYNOPSIS

    my $tally = Permutl::Score::tally( [ 'Killed', 'Survived', 'Timeout' ] );
    printf "%.1f%%\n", $tally->{score};

=head1 FUNCTIONS

=head2 tally

Returns the count of every status, the total, the number of valid mutants, and the score.
A valid mutant is C<Killed>, C<Survived>, or C<NoCoverage>.
The score is the percentage of valid mutants that are C<Killed>, and it is undefined when no mutant is valid.
C<Timeout> is inconclusive, so it counts toward neither side.

=cut
