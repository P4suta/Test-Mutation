package ParentProcess;
use strict;
use warnings;

sub parent_pid { getppid() }

sub profile_pid {
    my ($initial_pid) = @_;
    my $group_pid = ($$ eq $initial_pid) ? $$ : getppid();
    return $group_pid;
}

1;
