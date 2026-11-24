package Raised;
use v5.36;
use Scalar::Util ();

# What ends a piece of code, for a test that expects a failure.
# A typed error gives its kind, its identifier, and its message, and any other exception gives its text.
# Code that returns gives nothing, so an assertion on the answer fails when no error was raised.
sub error ($code) {
    my $lived = eval { $code->(); 1 };
    return if $lived;
    my $error = $@;
    return "$error" if !Scalar::Util::blessed($error) || !$error->isa('Test::Mutation::Error');
    return [ $error->kind, $error->id, $error->message ];
}

# The words of the failure alone: the message of a typed error, and the text of another exception.
sub message ($code) {
    my $error = error($code);
    return ref $error ? $error->[2] : $error;
}

1;
