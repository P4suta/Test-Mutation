package Corpus::PodData;
use v5.36;

=head1 NAME

Corpus::PodData - code mixed with documentation

=head1 SYNOPSIS

    my $n = 1 + 2;    # not code

=cut

sub lines {
    my @lines = <DATA>;
    return scalar(@lines) + 0;
}

=head2 lines

Counts the data lines, as in C<1 + 1>.

=cut

sub flip ($flag) {
    return !$flag;
}

1;

__DATA__
alpha + beta
gamma == delta
