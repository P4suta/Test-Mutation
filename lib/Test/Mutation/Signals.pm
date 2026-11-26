package Test::Mutation::Signals;
use v5.36;
use Types::Standard qw(Bool CodeRef Defined Dict Enum FileHandle Int Maybe Undef);
use Type::Params    qw(signature_for);
use Test::Mutation::Event;
use Test::Mutation::Exit;
use Test::Mutation::Interrupted;

our $VERSION = '0.001';

my @SIGNALS = Test::Mutation::Exit::signals()->@*;
my $STATE   = Dict [ owner => Int, signal => Maybe [ Enum [@SIGNALS] ], raised => Bool, deferred => Bool ];

# The state of the watch that the process stands under, and the handle of the code that waits under it.
my %HELD;

signature_for decide => ( positional => [ $STATE, Int ], returns => Enum [qw(default record)] );

sub decide ( $state, $pid ) {
    return $pid == $state->{owner} ? 'record' : 'default';
}

signature_for due => ( positional => [$STATE], returns => Bool );

sub due ($state) {
    return defined $state->{signal} && !$state->{raised} && !$state->{deferred} ? 1 : 0;
}

# A handler that died where the signal met the code would die inside a library that catches every error.
# It notes the signal, and the work ends at a check of its own.
sub _arrived ($signal) {
    my $watch = $HELD{watch};
    if ( decide( $watch, $$ ) eq 'default' ) {

        # A process that the owner started holds nothing of the run, so the signal ends it as it ends any program.
        $SIG{$signal} = 'DEFAULT';    ## no critic (Variables::RequireLocalizedPunctuationVars)
        kill $signal, $$;
        return;
    }
    $watch->{signal} = $signal if !defined $watch->{signal};

    # A full pipe already wakes the reader, so a write that fails loses nothing.
    syswrite $HELD{wake}, q{.} if $HELD{wake};
    return;
}

signature_for watch => ( positional => [CodeRef], returns => Defined );

sub watch ($code) {
    return $code->() if $HELD{watch};
    local $HELD{watch} = { owner => $$, signal => undef, raised => 0, deferred => 0 };
    local @SIG{@SIGNALS} = ( \&_arrived ) x @SIGNALS;
    return $code->();
}

signature_for waking => ( positional => [ FileHandle, CodeRef ], returns => Defined );

# Perl runs a handler after the system call that the signal met, so a signal just before a wait would wait with it.
# The byte on the handle ends such a wait at once.
sub waking ( $handle, $code ) {
    local $HELD{wake} = $handle;
    return $code->();
}

signature_for deferred => ( positional => [CodeRef], returns => Defined );

sub deferred ($code) {
    my $watch = $HELD{watch} or return $code->();
    my $value = do {
        local $watch->{deferred} = 1;
        $code->();
    };
    check();
    return $value;
}

signature_for check => ( positional => [], returns => Undef );

sub check () {
    Test::Mutation::Event::checkpoint();
    my $watch = $HELD{watch};
    return if !$watch || !due($watch);
    $watch->{raised} = 1;
    die Test::Mutation::Interrupted->new( signal => $watch->{signal} );    ## no critic (ErrorHandling::RequireCarping)
}

1;

__END__

=head1 NAME

Test::Mutation::Signals - end the work of a command once when a signal asks for it

=head1 SYNOPSIS

    my $status = Test::Mutation::Signals::watch(
        sub {
            for my $file (@files) {
                Test::Mutation::Signals::check();
                copy($file);
            }
            return Test::Mutation::Signals::deferred( sub { return remove_copies() } );
        }
    );

=head1 DESCRIPTION

The signals C<HUP>, C<INT>, C<QUIT>, C<PIPE>, and C<TERM> ask a program to end.
Under a watch, the handler notes the first of them, and the next check dies with a L<Test::Mutation::Interrupted>.
Every place that holds a resource lets that value pass after its release.
The work ends at a check and never where the signal happened to meet the code, so no library catches the interruption.
A later signal ends nothing again, so a release that has begun runs to its end.
A process that the watching one started holds nothing of the run, and a signal ends it as it ends a program without a watch.

=head1 FUNCTIONS

=head2 watch

Runs the code with a handler for each of the signals and returns its value.
The process that calls it owns the watch.
A watch inside a watch runs its code and leaves the signals to the outer one.

=head2 check

Dies with the interruption of a signal that waits, and returns otherwise.
A long step calls it at each point where it holds a state that the run can release.
Without a watch the function returns.

=head2 waking

    my $value = Test::Mutation::Signals::waking( $pipe, sub { return wait_for_events() } );

Runs the code and returns its value, and a signal that the watch notes meanwhile writes one byte to the handle.
Code that waits in C<select> includes the other end of the pipe, so the signal ends the wait at once.

=head2 deferred

Runs the code and returns its value, and a check inside it holds a signal back.
The function checks once when the code has ended, so a release runs to its end before a signal ends the work.
Without a watch the function runs the code and no more.

=head2 decide

    my $action = Test::Mutation::Signals::decide( $state, $$ );

Returns what a signal calls for, from the state of the watch and the process that received it.
C<record> notes the signal in the process that owns the watch, and C<default> ends every other process.
The state holds the C<owner>, the first C<signal>, whether it was C<raised>, and whether a deferral holds it back.

=head2 due

    my $ends = Test::Mutation::Signals::due($state);

Returns true when a check ends the work: a signal waits, it ended nothing yet, and no deferral holds it back.

=cut
