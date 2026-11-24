package Test::Mutation::Exit;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef InstanceOf Int Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

has code    => ( is => 'ro', isa => Int, required => 1 );
has name    => ( is => 'ro', isa => Str, required => 1 );
has meaning => ( is => 'ro', isa => Str, required => 1 );

my @ROWS = (
    [ 0,   'success',         'the command did its work' ],
    [ 1,   'below-gate',      'the score is below the one that --min-score asks for' ],
    [ 2,   'usage',           'the command refuses its arguments or its configuration' ],
    [ 3,   'baseline-failed', 'a test fails without a mutant' ],
    [ 4,   'inconclusive',    'the run judged no mutant, or an error ended the command' ],
    [ 129, 'hangup',          'the signal HUP ended the run' ],
    [ 130, 'interrupt',       'the signal INT ended the run' ],
    [ 143, 'termination',     'the signal TERM ended the run' ],
);

signature_for rows => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Exit'] ] );

sub rows () {
    return [ map { __PACKAGE__->new( code => $_->[0], name => $_->[1], meaning => $_->[2] ) } @ROWS ];
}

1;

__END__

=head1 NAME

Test::Mutation::Exit - the table of the exit statuses of the command

=head1 SYNOPSIS

    for my $exit ( Test::Mutation::Exit::rows()->@* ) {
        printf "%3d  %s\n", $exit->code, $exit->meaning;
    }

=head1 DESCRIPTION

The table states every exit status that the command itself returns.
C<mutation exec> also returns the status of the command that it runs.
The table describes the command as it stands, where status 4 has two meanings.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Exit> for every exit status, in rising order.

=head1 ATTRIBUTES

=head2 code

The exit status.

=head2 name

A short name for the status.

=head2 meaning

What the status states about the command.

=cut
