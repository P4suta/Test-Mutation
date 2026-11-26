use strict;
use warnings;
use Test::More tests => 1;
open my $result, '-|', $^X, 'bin/total', 4, 2 or die "launch: $!";
my $line = <$result>;
close $result or die "command failed: $?";
is $line, "6|bin/total|bin/total|8|payload\n", 'the total, invocation path, source location, and data';
