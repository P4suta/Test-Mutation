package Test::Mutation::Report::Progress;
use v5.36;
use List::Util      qw(max);
use Types::Standard qw(Bool HashRef Int Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Status;

our $VERSION = '0.001';

my $LOG_LINES = 10;

signature_for line => ( positional => [ Int, Int, HashRef [Int] ], returns => Str );

sub line ( $done, $total, $counts ) {
    my @parts = map { "$counts->{ $_->name } " . $_->word }
      grep { $_->progress && $counts->{ $_->name } } Test::Mutation::Status::rows()->@*;
    my $position = sprintf '[%*d/%d]', length $total, $done, $total;
    return @parts ? "$position " . join ', ', @parts : $position;
}

signature_for due => ( positional => [ Int, Int ], returns => Bool );

sub due ( $done, $total ) {
    my $step = max( 1, int $total / $LOG_LINES );
    return $done == $total || $done % $step == 0 ? 1 : 0;
}

signature_for update => ( positional => [ Int, Int, HashRef [Int], Bool ], returns => Str );

sub update ( $done, $total, $counts, $in_place ) {
    my $line = line( $done, $total, $counts );
    return "\r$line" . ( $done == $total ? "\n" : q{} ) if $in_place;
    return due( $done, $total ) ? "$line\n" : q{};
}

1;

__END__

=head1 NAME

Test::Mutation::Report::Progress - format the progress of a run

=head1 SYNOPSIS

    print {*STDERR} Test::Mutation::Report::Progress::line( $done, $total, \%counts ), "\n"
      if Test::Mutation::Report::Progress::due( $done, $total );

=head1 FUNCTIONS

=head2 line

Returns the position in the run and the count of every status that has a mutant and that L<Test::Mutation::Status> marks for the progress line.

=head2 due

True when a log should receive a line: at every tenth of a large run, at every mutant of a small run, and at the end.

=head2 update

Returns the text to print after a mutant.
A terminal gets the line after a carriage return, and a line feed once the run is complete.
A log gets the line when it is due, and nothing otherwise.

=cut
