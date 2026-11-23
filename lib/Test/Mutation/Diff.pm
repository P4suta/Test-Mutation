package Test::Mutation::Diff;
use v5.36;
use Types::Standard qw(ArrayRef Bool HashRef Int Str Tuple);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my $RANGES = ArrayRef [ Tuple [ Int, Int ] ];

signature_for changed_lines => ( positional => [Str], returns => HashRef [$RANGES] );

sub changed_lines ($diff) {
    my %changed;
    my $path;
    for my $line ( split /\n/, $diff ) {
        if ( $line =~ m{\A[+][+][+] (?:b/(.*)|/dev/null)\z} ) {
            $path = $1;
            next;
        }
        next if !defined $path;
        my ( $start, $length ) = $line =~ /\A @@ [ ] -[0-9,]+ [ ] [+] ([0-9]+) (?: , ([0-9]+) )? [ ] @@/x or next;
        $length = 1 if !defined $length;
        push $changed{$path}->@*, [ 0 + $start, $start + $length - 1 ] if $length > 0;
    }
    return \%changed;
}

signature_for touches => ( positional => [ $RANGES, Int, Int ], returns => Bool );

sub touches ( $ranges, $first, $last ) {
    for my $range ( $ranges->@* ) {
        return 1 if $range->[0] <= $last && $range->[1] >= $first;
    }
    return 0;
}

1;

__END__

=head1 NAME

Test::Mutation::Diff - find the lines a unified diff changed

=head1 SYNOPSIS

    my $changed = Test::Mutation::Diff::changed_lines($diff_text);
    my $touched = Test::Mutation::Diff::touches( $changed->{'lib/A.pm'}, 10, 12 );

=head1 FUNCTIONS

=head2 changed_lines

Reads a unified diff and returns, for each file, the line ranges that the new side added or modified.
Deleted lines and deleted files yield no range.

=head2 touches

True when the lines from C<$first> to C<$last> overlap one of the ranges.

=cut
