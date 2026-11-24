package Kills;
use v5.36;
use File::Find ();
use File::Path ();
use File::Spec ();
use File::Temp ();
use POSIX      ();
use Judge;
use Test::Mutation::Runner;

# The false-kill oracle: a killing test runs again with its mutant, and its output names the cause of the failure.

my $SECONDS = 60;

# A kill of these classes measures no behavior, and each one is a finding of its mutator.
my %FALSE = (
    resolution   => 'kills through an unresolved call',
    untrue       => 'kills through a file without a true value',
    compile      => 'kills through code that perl refuses',
    unreproduced => 'has a kill that the rerun does not reproduce',
);

sub classes () {
    return qw(assertion exception load-death untrue resolution compile unreproduced unserved timeout);
}

# The switch of taint mode that the first line of a test asks for, as the run reads it.
sub taint_switch ($path) {
    open my $handle, '<', $path or die "read $path: $!\n";
    my $first = readline $handle;
    close $handle or die "close $path: $!\n";
    return defined $first && $first =~ /\A[#]!.*perl.*\s-\w*([Tt])/ ? "-$1" : ();
}

# The command of a test as the run starts it: the library switches in full, and the taint switch of the test.
sub command ( $config, $test ) {
    my $root     = $config->root;
    my @switches = map { s{\A-I(?=[^/])}{-I$root/}r } $config->switch->@*;
    return [ $config->perl, @switches, taint_switch("$root/$test"), $test ];
}

sub _slurp ($path) {
    open my $handle, '<:raw', $path or die "read $path: $!\n";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!\n";
    return defined $text ? $text : q{};
}

# The code runs in a child in the root of the project, with both output handles on one file.
# The child leads a group of its own, so the bound stops every process that the code starts.
sub _bounded ( $root, $seconds, $code ) {
    my $output = File::Temp->new;
    my $pid    = fork;
    die "fork: $!\n" if !defined $pid;
    if ( !$pid ) {
        setpgrp 0, 0;
        my $ready =
             chdir($root)
          && open( STDIN,  '<', File::Spec->devnull )
          && open( STDOUT, '>', $output->filename )
          && open STDERR, '>&', \*STDOUT;
        my $status = $ready ? eval { $code->() } : undef;
        POSIX::_exit( defined $status ? $status : 125 );
    }
    my $stopped = 0;
    local $SIG{ALRM} = sub { $stopped = 1; kill 'KILL', -$pid };
    alarm $seconds;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;
    return { status => $stopped ? undef : $status >> 8, timed_out => $stopped, output => _slurp( $output->filename ) };
}

# The exit status of a test that runs without a mutant.
sub plain ( $config, $test, $seconds = $SECONDS ) {
    my @command = command( $config, $test )->@*;
    return _bounded(
        $config->root,
        $seconds,
        sub {
            system { $command[0] } @command;
            return $? & 127 ? 128 + ( $? & 127 ) : $? >> 8;
        }
    );
}

# The test runs again with the mutant in place, through the command that `mutation exec` uses.
sub rerun ( $config, $source, $mutant, $test, $seconds = $SECONDS ) {
    my $command = command( $config, $test );
    return _bounded( $config->root, $seconds,
        sub { return Test::Mutation::Runner::run_command( $config, $source, $mutant, $command ) } );
}

sub _named_calls ($output) {
    my @names = (
        $output =~ /Undefined subroutine &([\w:]+) called/g,
        $output =~ /Can't locate object method "(\w+)" via package/g
    );
    return map { /(\w+)\z/ } @names;
}

sub _introduced ( $mutant, $name ) {
    return $mutant->replacement =~ /\b\Q$name\E\b/ && $mutant->original !~ /\b\Q$name\E\b/ ? 1 : 0;
}

# The class of a run of a killing test.
# `compiles` answers whether perl compiles the mutated file, and a death in a block of the compilation counts as compiled.
# `tainted` marks a test under taint mode, where perl reads neither the switches nor the library of the environment.
# A test that the bound stopped has the class of the failure that it printed first, as the run stops a test there.
sub class_of ( $mutant, $run, $compiles, %arg ) {
    my $output = $run->{output};
    return $arg{tainted} ? 'unserved' : 'unreproduced' if !$run->{timed_out} && !$run->{status};
    return 'resolution'                                if grep { _introduced( $mutant, $_ ) } _named_calls($output);
    return 'untrue'                                    if $output =~ /did not return a true value/;
    if ( $output =~ /^(?:#\s+)?(?:Compilation failed in require|BEGIN failed--compilation aborted)/m ) {
        return $compiles->() ? 'load-death' : 'compile';
    }
    return 'assertion' if $output =~ /^\s*not ok\b/m;
    return $run->{timed_out} ? 'timeout' : 'exception';
}

# Perl compiles the mutated file as a program, with the library of the project.
sub _compiles ( $config, $source, $mutant ) {
    my $root    = $config->root;
    my @include = map { m{\A-I(.+)\z} ? ( $1 =~ m{\A/} ? $1 : "$root/$1" ) : () } $config->switch->@*;
    my $bytes   = $source->to_bytes( $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement ) );
    my $verdict = Judge::reference_calls( $bytes, include => \@include );
    return $verdict->{compiled} || $verdict->{diagnostics} =~ /^(?:BEGIN|UNITCHECK|CHECK) failed--/m ? 1 : 0;
}

# A killing test that runs again with its mutant, with the class of its output.
sub judged ( $config, $source, $mutant, $test, $seconds = $SECONDS ) {
    my $run     = rerun( $config, $source, $mutant, $test, $seconds );
    my $tainted = taint_switch( $config->root . "/$test" ) ? 1 : 0;
    my $class   = class_of( $mutant, $run, sub { _compiles( $config, $source, $mutant ) }, tainted => $tainted );
    return { $run->%*, mutant => $mutant, mutator => $mutant->mutator, test => $test, class => $class };
}

# The findings of a list of kills, each a hash with a mutator and a class.
# A test under taint mode gets no mutant from the command at all, which is one finding whatever the mutator.
sub findings (@kills) {
    my %found;
    for my $kill (@kills) {
        my $class = $kill->{class};
        $found{"$kill->{mutator} $FALSE{$class}"}                         = 1 if $FALSE{$class};
        $found{'run_command serves no mutant to a test under taint mode'} = 1 if $class eq 'unserved';
    }
    my @found = sort keys %found;
    return @found;
}

# A copy of some directories of the project, below a directory that the caller owns.
sub copied ( $target, @directories ) {
    for my $directory (@directories) {
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    my $path = $File::Find::name;
                    return File::Path::make_path("$target/$path") if -d $path;
                    open my $in,  '<:raw', $path           or die "read $path: $!\n";
                    open my $out, '>:raw', "$target/$path" or die "write $target/$path: $!\n";
                    print {$out} do { local $/ = undef; readline $in }
                      or die "copy $path: $!\n";
                    close $out or die "close $target/$path: $!\n";
                    close $in  or die "close $path: $!\n";
                },
            },
            $directory,
        );
    }
    return $target;
}

1;
