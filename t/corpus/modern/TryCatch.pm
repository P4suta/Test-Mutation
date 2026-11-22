package Corpus::TryCatch;
use v5.40;

sub parse ($text) {
    try {
        die "empty\n" unless length $text;
        return $text + 0;
    }
    catch ($error) {
        return -1 if $error eq "empty\n";
        die $error;
    }
}

sub guarded ($code) {
    my $calls = 0;
    try {
        $code->();
    }
    catch ($error) {
        $calls--;
    }
    finally {
        $calls++;
    }
    return $calls;
}

1;
