package Bounded;
use v5.36;
use Time::HiRes ();

my $STOPPED = "the bound stopped the code\n";

# Runs the code under a limit of seconds.
# The answer is true and the values of the code when it ended, and false alone when the limit stopped it.
# A death of the code passes through, so the caller reads its reason.
sub ended ( $seconds, $code ) {
    my @values;
    my $ended = eval {
        local $SIG{ALRM} = sub { die $STOPPED };
        Time::HiRes::alarm($seconds);
        @values = $code->();
        Time::HiRes::alarm(0);
        1;
    };
    my $reason = $@;
    Time::HiRes::alarm(0);
    return ( 1, @values ) if $ended;
    die $reason           if $reason ne $STOPPED;
    return 0;
}

# Whether an error is the stop of the bound, which code that catches its own errors passes on to the bound.
sub stopped ($error) {
    return $error eq $STOPPED ? 1 : 0;
}

1;
