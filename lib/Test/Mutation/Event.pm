package Test::Mutation::Event;
use v5.36;
use Time::HiRes     ();
use Types::Standard qw(ArrayRef CodeRef Defined Enum Str Undef);
use Type::Params    qw(signature_for);
use Test::Mutation::Clock;

our $VERSION = '0.001';

my %WATCH;
my $CLOCK    = Test::Mutation::Clock->new;
my $INTERVAL = 5;
my @PHASES   = qw(resolve analyze plan acquire build baseline mutants conclude release);

signature_for phases => ( positional => [], returns => ArrayRef [Str] );

sub phases () {
    return [@PHASES];
}

signature_for phase => ( positional => [ CodeRef, Enum [@PHASES] ], returns => Undef );

sub phase ( $listener, $name ) {
    my $facts = { name => $name, time => Time::HiRes::time() };
    $listener->( 'phase',           $facts );
    $listener->( "${name}_started", $facts ) if $name eq 'baseline' || $name eq 'mutants';
    return;
}

signature_for during => (
    positional => [
        CodeRef, CodeRef, CodeRef,
        {
            default => sub {
                sub { $CLOCK->now }
            }
        }
    ],
    returns => Defined,
);

sub during ( $listener, $work, $clock ) {
    local $WATCH{active} = { pid => $$, listener => $listener, clock => $clock, next => $clock->() + $INTERVAL };
    return $work->();
}

signature_for checkpoint => ( positional => [], returns => Undef );

sub checkpoint () {
    my $watch = $WATCH{active} or return;
    return if $watch->{pid} != $$;
    my $now = $watch->{clock}->();
    return if $now < $watch->{next};
    $watch->{next} = $now + $INTERVAL;
    $watch->{listener}->( 'tick', { time => $now } );
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

=head2 during

Runs the supplied work while a listener and monotonic clock own the progress ticks in the current process.
An optional clock supplies seconds for deterministic callers.

=head2 checkpoint

Publishes a tick when five seconds have passed since the last tick.
Child processes leave ticks to the process that started the measurement.

=cut
