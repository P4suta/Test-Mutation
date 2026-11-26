use v5.36;
use Test2::V0;
use Cwd         ();
use File::Temp  ();
use POSIX       ();
use Time::HiRes ();
use Test::Mutation::Tree;
use Test::Mutation::Workspace;
use Test::Mutation::Workspace::Processes;

my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $parent  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
local $ENV{TMPDIR} = $parent;
my $first = Test::Mutation::Workspace::acquire($project);
my $held  = $first->directory;
like $held, qr{\A\Q$parent\E/mutation-[[:alnum:]]{6}\z}, 'the private workspace uses the selected temporary parent';
ok -f "$held/owner", 'the workspace contains its lock';
ok -d "$held/$_",    "$_ is inside the workspace" for qw(tree slot work);
my $other = Test::Mutation::Workspace::acquire($project);
isnt $other->directory, $held, 'two simultaneous runs have separate directories';
ok -d $held, 'reclamation respects a live lock';

pipe my $ready, my $signal or die "pipe: $!";
my $worker = fork;
die "fork: $!" if !defined $worker;
if ( !$worker ) {
    close $ready or die $!;
    my $lease = Test::Mutation::Workspace::Processes::inherit( $other->directory . '/processes' );
    setpgrp 0, 0 or die $!;
    syswrite $signal, '!' or die $!;
    exec {$^X} $^X, '-e', 'sleep 20' or POSIX::_exit(1);
}
close $signal or die $!;
is sysread( $ready, my $byte, 1 ), 1, 'the worker took the lease before leaving its process group';
close $ready or die $!;
ok Test::Mutation::Workspace::Processes::finish( $held . '/processes' ), 'finishing an independent run succeeds';
ok kill( 0, $worker ),                                                   'the other run keeps its worker';
ok Test::Mutation::Workspace::Processes::finish( $other->directory . '/processes' ),
  'the escaped worker releases its lease';
my $done = 0;

for ( 1 .. 100 ) {
    $done = waitpid $worker, POSIX::WNOHANG();
    last if $done == $worker;
    Time::HiRes::sleep(0.01);
}
is $done, $worker, 'cleanup ended the worker before the wait deadline';
if ( $done != $worker ) { kill 'TERM', $worker; waitpid $worker, 0 }
is $? & 127, 9, 'cleanup ended the worker that retained the lease';

my $pid = fork;
die "fork: $!" if !defined $pid;
if ( !$pid ) {
    POSIX::_exit( $first->release(0) ? 1 : 0 );
}
waitpid $pid, 0;
is $? >> 8, 0, 'a child receives a refusal when releasing its parent workspace';
ok -d $held,           'a child cannot release the workspace of its parent';
ok $first->release(0), 'the acquiring process releases its workspace';
ok !-e $held,          'success removes the directory';
ok $first->release(0), 'the completed release can be retried';

my $kept = $other->directory;
ok $other->release(1), 'an explicit request retains a finished run';
my $stale     = Test::Mutation::Workspace::acquire($project);
my $abandoned = $stale->directory;
undef $stale;
my $unrelated = Test::Mutation::Tree::temporary( $parent, 'mutation-' );
open my $ordinary, '>', "$unrelated/owner" or die $!;
print {$ordinary} "unrelated application\n" or die $!;
close $ordinary                             or die $!;
my $next = Test::Mutation::Workspace::acquire($project);
ok !-e $abandoned,        'a later run removes an abandoned workspace';
ok -d $kept,              'a kept workspace survives a later start';
ok -f "$unrelated/owner", 'another application can use the same directory prefix safely';
$next->release(0);

subtest 'an incomplete release preserves the requested recovery tree across the next measurement' => sub {
    my $workspace = Test::Mutation::Workspace::acquire($project);
    my $directory = $workspace->directory;
    open my $backup, '>', "$directory/tree/original" or die "open backup: $!";
    print {$backup} "original\n" or die "write backup: $!";
    close $backup                or die "close backup: $!";
    {
        no warnings 'redefine';
        local *Test::Mutation::Workspace::Processes::finish = sub { return 0 };
        ok !$workspace->release(1), 'a live descendant leaves process cleanup incomplete';
        ok -f "$directory/kept",    'the backup is retained as soon as recovery is requested';
        ok !$workspace->release(1), 'a retry while the descendant lives still reports incomplete cleanup';
    }
    undef $workspace;
    my $later = Test::Mutation::Workspace::acquire($project);
    ok -f "$directory/tree/original", 'a subsequent run cannot reclaim a backup marked for recovery';
    ok $later->release(0),            'the following measurement releases its own workspace';
};

local $ENV{TMPDIR} = $project;
my $outside = Test::Mutation::Workspace::acquire($project);
unlike $outside->directory, qr{\A\Q$project\E(?:/|\z)}, 'a temporary parent inside the checkout falls back outside';
$outside->release(0);

done_testing;
