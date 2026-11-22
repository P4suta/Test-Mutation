use strict;
use warnings;
use Test::More tests => 1;

my $pid = fork;
die "fork: $!" if !defined $pid;
if ( !$pid ) {
    require Forked;
    exit( Forked::triple(2) == 6 ? 0 : 1 );
}
waitpid $pid, 0;
is $? >> 8, 0, 'the child computed the triple';
