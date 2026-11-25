package Test::Mutation::Event;
use v5.36;
use Time::HiRes     ();
use Types::Standard qw(ArrayRef CodeRef Enum Str Undef);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my @PHASES = qw(resolve analyze plan acquire build baseline mutants conclude release);

signature_for phases => ( positional => [], returns => ArrayRef [Str] );

sub phases () {
    return [@PHASES];
}

signature_for phase => ( positional => [ CodeRef, Enum [@PHASES] ], returns => Undef );

sub phase ( $listener, $name ) {
    $listener->( 'phase', { name => $name, time => Time::HiRes::time() } );
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Event - name the phases a measurement enters

=head1 SYNOPSIS

    Test::Mutation::Event::phase($listener, 'analyze');

=head1 FUNCTIONS

=head2 phases

Returns the ordered phase names of a complete measurement.

=head2 phase

Sends the name and start time of a phase to the listener.

=cut
