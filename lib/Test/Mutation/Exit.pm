package Test::Mutation::Exit;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Enum InstanceOf Int Maybe Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

# Each row: the status, the name of the outcome, the signal of a status that a signal gives, and the meaning.
my @ROWS = (
    [ 0,   'success',         undef, 'the command did its work' ],
    [ 1,   'below-gate',      undef, 'the score is below the one that --min-score asks for' ],
    [ 2,   'usage',           undef, 'the command refuses its arguments, its configuration, or a file that they name' ],
    [ 3,   'baseline-failed', undef, 'a test fails without a mutant' ],
    [ 4,   'inconclusive',    undef, 'the run states no score' ],
    [ 5,   'environment',     undef, 'a file, Git, or a process kept the command from its work' ],
    [ 6,   'internal',        undef, 'an error inside mutation, which is a defect of the tool' ],
    [ 125, 'exec-failed',     undef, 'mutation exec failed apart from the command that it runs' ],
    [ 126, 'command-not-runnable', undef,  'the command of mutation exec exists, and the system refuses to run it' ],
    [ 127, 'command-not-found',    undef,  'mutation exec finds no command of the given name' ],
    [ 129, 'hangup',               'HUP',  'the signal HUP ended the run' ],
    [ 130, 'interrupt',            'INT',  'the signal INT ended the run' ],
    [ 131, 'quit',                 'QUIT', 'the signal QUIT ended the run' ],
    [ 141, 'pipe',                 'PIPE', 'the signal PIPE ended the run' ],
    [ 143, 'termination',          'TERM', 'the signal TERM ended the run' ],
);
my %CODE    = map { $_->[1] => $_->[0] } @ROWS;
my %SIGNAL  = map { $_->[2] => $_->[0] } grep { defined $_->[2] } @ROWS;
my @SIGNALS = map { $_->[2] } grep { defined $_->[2] } @ROWS;

has code    => ( is => 'ro', isa => Int, required => 1 );
has name    => ( is => 'ro', isa => Str, required => 1 );
has signal  => ( is => 'ro', isa => Maybe [ Enum [@SIGNALS] ], required => 1 );
has meaning => ( is => 'ro', isa => Str, required => 1 );

signature_for rows => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Exit'] ] );

sub rows () {
    return [ map { __PACKAGE__->new( code => $_->[0], name => $_->[1], signal => $_->[2], meaning => $_->[3] ) }
          @ROWS ];
}

signature_for of => ( positional => [ Enum [ map { $_->[1] } @ROWS ] ], returns => Int );

sub of ($name) {
    return $CODE{$name};
}

signature_for signals => ( positional => [], returns => ArrayRef [Str] );

sub signals () {
    return [@SIGNALS];
}

signature_for of_signal => ( positional => [ Enum [@SIGNALS] ], returns => Int );

sub of_signal ($signal) {
    return $SIGNAL{$signal};
}

1;

__END__

=head1 NAME

Test::Mutation::Exit - the table of the exit statuses of the command

=head1 SYNOPSIS

    for my $exit ( Test::Mutation::Exit::rows()->@* ) {
        printf "%3d  %s\n", $exit->code, $exit->meaning;
    }
    exit Test::Mutation::Exit::of('usage');

=head1 DESCRIPTION

The table states every exit status that the command itself returns, and no other place holds such a number.
C<mutation exec> also returns the status of the command that it runs.
For its own failures it follows C<env> of POSIX: 125 when it fails itself, 126 when the command exists and fails to run, and 127 when no such command exists.
A signal that the command handles ends it with 128 plus the number of the signal, the status a shell reports for it.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Exit> for every exit status, in rising order.

=head2 of

    my $status = Test::Mutation::Exit::of('environment');

Returns the exit status of the outcome with the given name.

=head2 signals

Returns the names of the signals that have a row, which are the signals that the command handles.

=head2 of_signal

    my $status = Test::Mutation::Exit::of_signal('TERM');

Returns the exit status of a run that the signal ended.

=head1 ATTRIBUTES

=head2 code

The exit status.

=head2 name

The name of the outcome that the status states.

=head2 signal

The name of the signal that gives the status, and nothing for a status that no signal gives.

=head2 meaning

What the status states about the command.

=cut
