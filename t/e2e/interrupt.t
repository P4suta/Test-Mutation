use v5.36;
use Test2::V0;
use Cwd         ();
use File::Temp  ();
use Time::HiRes ();
use lib 't/e2e/lib';
use Fixture qw(copy_of write_file);

my $library = Cwd::abs_path('lib');
my $command = Cwd::abs_path('bin') . '/mutation';

sub processes_under ($root) {
    open my $ps, q{-|}, 'ps', '-axo', 'pid=,command=' or die "ps: $!";
    my @lines = grep { index( $_, $root ) >= 0 } readline $ps;
    close $ps or die "ps: $!";
    return \@lines;
}

sub wait_for ($condition) {
    for ( 1 .. 100 ) {
        return 1 if $condition->();
        Time::HiRes::sleep(0.1);
    }
    return 0;
}

sub text_of ($path) {
    open my $handle, '<', $path or return q{};
    local $/ = undef;
    my $text = readline $handle;
    return defined $text ? $text : q{};
}

my %status_of = ( HUP => 129, INT => 130, TERM => 143 );

for my $signal ( sort keys %status_of ) {
    subtest "SIG$signal ends the tests and removes the work directory" => sub {
        my $root = copy_of('calc');
        write_file( "$root/t/slow.t", "use Test::More tests => 1;\nuse Calc;\nsleep 30;\nok 1, 'slept';\n" );
        my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
        local $ENV{TMPDIR} = $scratch;

        my $pid = fork;
        die "fork: $!" if !defined $pid;
        if ( !$pid ) {
            chdir $root or die "chdir: $!";
            open STDIN,  '<', '/dev/null'        or die "stdin: $!";
            open STDOUT, '>', "$root/stdout.txt" or die "stdout: $!";
            open STDERR, '>', "$root/stderr.txt" or die "stderr: $!";
            exec {$^X} $^X, "-I$library", $command, '--jobs', 2, '--format', 'terminal' or die "exec: $!";
        }

        ok wait_for(
            sub {
                scalar grep { /slow[.]t/ } processes_under($root)->@*;
            }
          ),
          'the slow test is running';
        kill $signal, $pid;
        waitpid $pid, 0;
        is $? >> 8, $status_of{$signal}, 'the exit status names the signal';
        like text_of("$root/stderr.txt"), qr/^mutation: interrupted by SIG$signal$/m, 'and so does standard error';

        ok wait_for( sub { !processes_under($root)->@* } ), 'no process of the run is left'
          or diag join q{}, processes_under($root)->@*;
        ok !glob("$root/.mutation/run-*"), 'the work directory is removed';
        is [ glob "$scratch/*" ], [], 'and so are the copies of the project';
    };
}

subtest 'a signal during the mutant runs keeps the finished results' => sub {
    my $root = copy_of('calc');
    write_file( "$root/t/slow.t",
        "use Test::More tests => 1;\nuse Calc;\nselect undef, undef, undef, 0.7;\nis Calc::add( 1, 1 ), 2, 'adds';\n" );

    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        chdir $root or die "chdir: $!";
        open STDIN,  '<', '/dev/null'        or die "stdin: $!";
        open STDOUT, '>', "$root/stdout.txt" or die "stdout: $!";
        open STDERR, '>', "$root/stderr.txt" or die "stderr: $!";
        exec {$^X} $^X, "-I$library", $command, '--jobs', 1, '--format', 'terminal', '--format', 'json'
          or die "exec: $!";
    }

    my $read = sub ($name) {
        open my $handle, '<', "$root/$name" or return q{};
        local $/ = undef;
        my $text = readline $handle;
        return defined $text ? $text : q{};
    };
    ok wait_for( sub { $read->('stderr.txt') =~ /^\[ *[1-9]\d*\/\d+\]/m } ), 'a mutant has finished';
    kill 'TERM', $pid;
    waitpid $pid, 0;
    is $? >> 8, 143, 'the exit status names the signal';

    like $read->('stdout.txt'), qr/^\d+ mutants: .*\b[1-9]\d* pending$/m,
      'the summary counts the mutants that did not run';
    like $read->('stdout.txt'), qr/^The run was interrupted by SIGTERM\.$/m, 'the summary names the signal';
    like $read->('stderr.txt'), qr/^mutation: interrupted by SIGTERM$/m,     'and so does standard error';
    like $read->('mutation-report/mutation.json'), qr/"status"\s*:\s*"Pending"/,
      'the JSON report marks them as pending';
    ok !glob("$root/.mutation/run-*"), 'the work directory is removed';
};

done_testing;
