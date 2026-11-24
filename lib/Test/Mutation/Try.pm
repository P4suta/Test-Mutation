package Test::Mutation::Try;
use v5.36;
use Scalar::Util    ();
use Types::Standard qw(CodeRef Defined Dict Enum);
use Type::Params    qw(signature_for);
use Test::Mutation::Signals;

our $VERSION = '0.001';

signature_for attempt => (
    positional => [ CodeRef, Enum [qw(failure interruption)], { default => 'failure' } ],
    returns    => Dict [ value => Defined ] | Dict [ error => Defined ],
);

sub attempt ( $code, $catches ) {
    my $value;
    my $lived = eval { $value = $code->(); 1 };
    return { value => $value } if $lived;
    my $error       = $@;
    my $interrupted = Scalar::Util::blessed($error) && $error->isa('Test::Mutation::Interrupted');
    die $error if $catches eq 'failure' && $interrupted;    ## no critic (ErrorHandling::RequireCarping)
    return { error => $error };
}

signature_for with_cleanup => ( positional => [ CodeRef, CodeRef ], returns => Defined );

sub with_cleanup ( $code, $cleanup ) {
    my $owner   = $$;
    my $attempt = attempt( $code, 'interruption' );

    # A process that the code started holds no part of what the cleanup releases.
    Test::Mutation::Signals::deferred( sub { $cleanup->(); return 1 } ) if $$ == $owner;
    die $attempt->{error}                                               if exists $attempt->{error};    ## no critic (ErrorHandling::RequireCarping)
    return $attempt->{value};
}

1;

__END__

=head1 NAME

Test::Mutation::Try - the one place of the driver that catches an exception

=head1 SYNOPSIS

    my $attempt = Test::Mutation::Try::attempt( sub { return read_settings($path) } );
    my $settings = exists $attempt->{error} ? {} : $attempt->{value};

    my $result = Test::Mutation::Try::with_cleanup( sub { return measure($copy) }, sub { remove($copy) } );

=head1 DESCRIPTION

Code that catches an error decides what the error means, and a catch in many places decides it in many ways.
The driver catches in this module alone.
An interruption by a signal passes every catch that did not ask for it, so no place turns it into another error.

=head1 FUNCTIONS

=head2 attempt

Runs the code and returns a hash with its C<value>, or with the C<error> that ended it.
The code returns a defined value.
The second argument names what the call catches, and C<failure> is its default.
An interruption dies on through such a call, and the word C<interruption> returns it as the error too.

=head2 with_cleanup

Runs the code, then the cleanup, and returns the value of the code or dies with its error.
The cleanup runs after a value, an error, and an interruption alike, and a signal waits until it has ended.
It runs in the process that made the call alone.
A cleanup that dies ends the call with its own error.

=cut
