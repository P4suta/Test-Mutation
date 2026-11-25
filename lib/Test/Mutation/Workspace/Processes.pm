package Test::Mutation::Workspace::Processes;
use v5.36;
use Fcntl           qw(:DEFAULT :flock F_SETFD);
use List::Util      ();
use Time::HiRes     ();
use Types::Standard qw(Bool FileHandle Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;

our $VERSION = '0.001';

signature_for inherit => ( positional => [Str], returns => FileHandle );

sub inherit ($path) {
    sysopen my $file, $path, O_RDONLY | O_NOFOLLOW
      or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    flock $file, LOCK_SH or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    fcntl $file, F_SETFD, 0 or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    return $file;
}

signature_for finish => ( positional => [Str], returns => Bool );

sub finish ($path) {
    return 0 unless sysopen my $file, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK;
    return 0 unless -f $file;
    return 1 if flock $file, LOCK_EX | LOCK_NB;
    my @identity = ( stat $file )[ 0, 1 ];
    my @holders  = -d '/proc/self/fd' ? _proc_holders( \@identity ) : _lsof_holders($path);
    kill 'KILL', @holders if @holders;
    my $until = Time::HiRes::time() + 1;
    while ( Time::HiRes::time() < $until ) {
        return 1 if flock $file, LOCK_EX | LOCK_NB;
        Time::HiRes::sleep(0.01);
    }
    return 0;
}

sub _proc_holders ( $identity, $proc = '/proc' ) {
    opendir my $processes, $proc or return;
    my @pids = grep { /\A[1-9][0-9]*\z/ && $_ != $$ } readdir $processes;
    return grep { _holds_lease( "$proc/$_", $identity ) } @pids;
}

sub _holds_lease ( $process, $identity ) {
    return 0 unless -o $process;
    my $directory = "$process/fd";
    opendir my $files, $directory or return 0;
    return List::Util::any {
        my @open = stat "$directory/$_";
        @open && $open[0] == $identity->[0] && $open[1] == $identity->[1];
    }
    grep { /\A[0-9]+\z/ } readdir $files;
}

sub _lsof_holders ($path) {
    no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    open my $listing, '-|', 'lsof', '-nP', '-w', '-a', '-u', $<, '-t', '--', $path or return;
    my @pids = grep { $_ != $$ } map { /\A([1-9][0-9]*)\s*\z/ ? $1 : () } readline $listing;
    close $listing or return;
    return @pids;
}

1;

__END__

=head1 NAME

Test::Mutation::Workspace::Processes - identify test descendants by an inherited workspace file

=head1 SYNOPSIS

    my $lease = Test::Mutation::Workspace::Processes::inherit($path);
    Test::Mutation::Workspace::Processes::finish($path);

=head1 FUNCTIONS

=head2 inherit

Opens a shared lock for a test process and keeps its descriptor open across C<exec>.
Forked descendants inherit the descriptor even when they leave the test process group.

=head2 finish

Returns immediately when every test has released its lock.
Otherwise the driver finds the processes holding the same file and ends them before removing the workspace.
Returns true when the driver acquires the exclusive lock.

=cut
