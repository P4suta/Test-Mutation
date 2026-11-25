use v5.36;
use Test2::V0;
use Fcntl      qw(:flock F_GETFD FD_CLOEXEC);
use File::Path qw(make_path);
use File::Temp ();
use POSIX      ();
use Test::Mutation::Workspace::Processes;

my $root  = File::Temp::tempdir( CLEANUP => 1 );
my $lease = "$root/processes";
open my $created, '>', $lease or die $!;
close $created or die $!;

subtest 'the lease survives exec and blocks an exclusive cleanup lock' => sub {
    my $held = Test::Mutation::Workspace::Processes::inherit($lease);
    is fcntl( $held, F_GETFD, 0 ) & FD_CLOEXEC, 0, 'a test retains its descriptor across exec';
    open my $writer, '<', $lease or die $!;
    ok !flock( $writer, LOCK_EX | LOCK_NB ), 'the shared lease prevents removal';
    close $held or die $!;
    ok flock( $writer, LOCK_EX | LOCK_NB ), 'ending the last test permits cleanup';
    close $writer or die $!;
    for
      my $operation ( \&Test::Mutation::Workspace::Processes::inherit, \&Test::Mutation::Workspace::Processes::finish )
    {
        like dies { $operation->( [] ) }, qr/type constraint "Str" [(]in \$_\[0\][)]/,
          'the public boundary requires a path';
    }
    symlink $lease, "$root/link" or die $!;
    like dies { Test::Mutation::Workspace::Processes::inherit("$root/link") }, qr/cannot read/,
      'a link cannot grant a lease';
    ok !Test::Mutation::Workspace::Processes::finish("$root/link"), 'cleanup never follows a link to a live lease';
    ok !Test::Mutation::Workspace::Processes::finish($root),        'a directory cannot act as a lease';
    ok !Test::Mutation::Workspace::Processes::finish("$root/gone"),
      'a missing lease cannot prove that cleanup finished';
};

subtest 'proc identifies an eligible process once by device and inode' => sub {
    my $holders = \&Test::Mutation::Workspace::Processes::_proc_holders;    ## no critic (Variables::ProtectPrivateVars)
    my $holds   = \&Test::Mutation::Workspace::Processes::_holds_lease;     ## no critic (Variables::ProtectPrivateVars)
    my $proc    = "$root/proc";
    my ( $holder, $decoy, $gone ) = map { $$ + $_ } 1 .. 3;
    make_path( "$proc/$holder/fd", "$proc/$decoy/fd", "$proc/$gone", "$proc/$$/fd", "$proc/notes/fd" );
    for my $path ( "$holder/fd/4", "$holder/fd/9", "$decoy/fd/non_numeric", "$$/fd/5", 'notes/fd/6' ) {
        symlink $lease, "$proc/$path" or die $!;
    }
    symlink "$root",         "$proc/$decoy/fd/2" or die $!;
    symlink "$root/deleted", "$proc/$decoy/fd/3" or die $!;
    my ( $dev, $ino ) = ( stat $lease )[ 0, 1 ];
    ok !$holds->( "$proc/absent", [ $dev, $ino ] ), 'an absent process cannot hold a lease';
    local $SIG{__WARN__} = sub { die @_ };
    is [ $holders->( [ $dev, $ino ], $proc ) ], ["$holder"],
      'only another process with a matching numbered descriptor is selected';
    for my $other ( [ $dev + 1, $ino ], [ $dev, $ino + 5000 ] ) {
        is [ $holders->( $other, $proc ) ], [], 'both fields of the file identity must match';
    }
    is [ $holders->( [ $dev, $ino ], "$proc/absent" ) ], [],
      'an unavailable process list supplies no process identifiers';
};

subtest 'lsof output is accepted only after a successful lookup for the current user and lease' => sub {
    my $holders = \&Test::Mutation::Workspace::Processes::_lsof_holders;    ## no critic (Variables::ProtectPrivateVars)
    my $bin     = "$root/bin";
    make_path($bin);
    open my $program, '>', "$bin/lsof" or die $!;
    print {$program} "#!$^X\n", <<'PROGRAM' or die $!;
use strict;
use warnings;
my $path = pop @ARGV;
exit 2 unless join(' ', @ARGV) eq "-nP -w -a -u $< -t --";
my $parent = getppid;
print "$parent\n0\n-2\nbad\n", $parent + 1, "\n";
exit($path eq 'lease with spaces' ? 0 : 1);
PROGRAM
    close $program or die $!;
    chmod 0755, "$bin/lsof" or die $!;
    local $ENV{PATH} = $bin;
    is [ $holders->('lease with spaces') ], [ $$ + 1 ],
      'the fallback excludes the driver and malformed process identifiers';
    is [ $holders->('lookup failed') ], [], 'a failed listing cannot authorize ending any process';
    unlink "$bin/lsof" or die $!;
    local $SIG{__WARN__} = sub { die @_ };
    is [ $holders->('missing executable') ], [], 'an unavailable process-listing command gives no holders';
};

subtest 'cleanup waits for the lock and observes its deadline' => sub {
    no warnings 'redefine';                                                         ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    local *Test::Mutation::Workspace::Processes::_proc_holders = sub { return };    ## no critic (Variables::ProtectPrivateVars)
    local *Test::Mutation::Workspace::Processes::_lsof_holders = sub { return };    ## no critic (Variables::ProtectPrivateVars)
    {
        local *Test::Mutation::Workspace::Processes::_proc_holders = sub { die 'unexpected process lookup' };    ## no critic (Variables::ProtectPrivateVars)
        local *Test::Mutation::Workspace::Processes::_lsof_holders = sub { die 'unexpected process lookup' };    ## no critic (Variables::ProtectPrivateVars)
        ok Test::Mutation::Workspace::Processes::finish($lease), 'a free lease requires no process lookup';
    }
    for my $release ( 0, 1 ) {
        my $held = Test::Mutation::Workspace::Processes::inherit($lease);
        my ( $clock, @sleeps ) = (0);
        local *Time::HiRes::time  = sub { $clock += 0.25; return $clock };
        local *Time::HiRes::sleep = sub ($seconds) {
            push @sleeps, $seconds;
            close $held or die $! if $release;
        };
        is Test::Mutation::Workspace::Processes::finish($lease), $release, 'success requires an exclusive lock';
        ok @sleeps > 0,                  'the driver waits between attempts';
        ok !grep( { $_ <= 0 } @sleeps ), 'each pause yields the processor';
    }
};

done_testing;
