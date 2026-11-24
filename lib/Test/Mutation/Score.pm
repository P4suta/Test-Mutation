package Test::Mutation::Score;
use v5.36;
use Types::Standard qw(ArrayRef Dict HashRef Int Maybe Num);
use Type::Params    qw(signature_for);
use Test::Mutation::Status;
use Test::Mutation::Types qw(StatusName);

our $VERSION = '0.001';

signature_for tally => (
    positional => [ ArrayRef [StatusName] ],
    returns    => Dict [ counts => HashRef [Int], total => Int, valid => Int, score => Maybe [Num] ],
);

sub tally ($statuses) {
    my %counts = map { $_ => 0 } Test::Mutation::Status::names()->@*;
    $counts{$_}++ for $statuses->@*;
    my %side = ( detected => 0, undetected => 0 );
    for my $row ( Test::Mutation::Status::rows()->@* ) {
        $side{ $row->role } += $counts{ $row->name };
    }
    my $detected = $side{detected};
    my $valid    = $detected + $side{undetected};
    return {
        counts => \%counts,
        total  => scalar $statuses->@*,
        valid  => $valid,
        score  => $valid ? 100 * $detected / $valid : undef,
    };
}

1;

__END__

=head1 NAME

Test::Mutation::Score - count statuses and compute the mutation score

=head1 SYNOPSIS

    my $tally = Test::Mutation::Score::tally( [ 'Killed', 'Survived', 'Timeout' ] );
    printf "%.1f%%\n", $tally->{score};

=head1 FUNCTIONS

=head2 tally

Returns the count of every status, the total, the number of valid mutants, and the score.
A valid mutant has a status whose role in L<Test::Mutation::Status> is C<detected> or C<undetected>.
The score is the percentage of valid mutants that are detected, and it is undefined when no mutant is valid.
C<Timeout> is inconclusive, so it counts toward neither side.

=cut
