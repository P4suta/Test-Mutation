package Discovery::Project;
use v5.36;
use Cwd         ();
use Digest::SHA ();
use File::Copy  ();
use File::Find  ();
use File::Path  ();
use File::Temp  ();
use POSIX       ();
use Time::HiRes ();

# A generated project stands in a scratch directory of its own, next to the registry of the processes its tests start.
# The scratch directory holds every file of a case, so one removal ends the case.

my $GRACE_SECONDS = 1;
my $PROVE_SECONDS = 30;
my %OUTSIDE       = map { $_ => 1 } '.mutation', 'mutation-report', '.git';
my %OWNER;

sub new ( $class, %arg ) {
    my $scratch = Cwd::abs_path( File::Temp::tempdir( 'discovery-XXXXXX', TMPDIR => 1 ) );
    my $name    = defined $arg{name} ? $arg{name} : 'project';
    my $self    = bless { scratch => $scratch, root => "$scratch/$name", registry => "$scratch/registry", count => 0 },
      $class;
    File::Path::make_path( $self->{root}, $self->{registry} );
    $OWNER{$scratch} = $$;
    return $self;
}

sub root     ($self) { return $self->{root} }
sub registry ($self) { return $self->{registry} }
sub scratch  ($self) { return $self->{scratch} }

# A new empty directory beside the project, for the files of one run.
sub directory ( $self, $purpose ) {
    my $path = sprintf '%s/%s-%d', $self->{scratch}, $purpose, ++$self->{count};
    File::Path::make_path($path);
    return $path;
}

sub write ( $self, $path, $content, %arg ) {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my $target = "$self->{root}/$path";
    my ($directory) = $target =~ m{\A(.*)/};
    File::Path::make_path($directory);
    open my $handle, '>:raw', $target or die "write $target: $!";
    print {$handle} $content or die "write $target: $!";
    close $handle            or die "close $target: $!";
    chmod $arg{mode}, $target or die "chmod $target: $!" if defined $arg{mode};
    utime $arg{time}, $arg{time}, $target or die "utime $target: $!" if defined $arg{time};
    return $target;
}

# A second project with the same files, for an oracle that may change them.
sub copy ($self) {
    my ($name) = $self->{root} =~ m{([^/]+)\z};
    my $copy = ref($self)->new( name => $name );
    my ( $from, $to ) = ( $self->{root}, $copy->{root} );
    my @directories;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if $File::Find::name eq $from;
                my $path = substr $File::Find::name, 1 + length $from;
                if ( $OUTSIDE{$path} ) {
                    $File::Find::prune = 1;
                    return;
                }
                my @status = lstat $File::Find::name or die "read $File::Find::name: $!";
                if ( -l _ ) {
                    symlink readlink($File::Find::name), "$to/$path" or die "link $to/$path: $!";
                }
                elsif ( -d _ ) {
                    mkdir "$to/$path" or die "create $to/$path: $!";
                    push @directories, [ "$to/$path", $status[2] & oct '7777' ];
                }
                elsif ( -f _ ) {
                    File::Copy::copy( $File::Find::name, "$to/$path" ) or die "copy $path: $!";
                    chmod $status[2] & oct('7777'), "$to/$path" or die "chmod $to/$path: $!";
                    utime @status[ 8, 9 ], "$to/$path" or die "utime $to/$path: $!";
                }
                return;
            },
        },
        $from,
    );
    chmod $_->[1], $_->[0] or die "chmod $_->[0]: $!" for reverse @directories;
    return $copy;
}

my $PROVE = <<'PERL';
use strict;
use warnings;
use App::Prove;
use TAP::Harness;
BEGIN { $INC{'Discovery/Recording.pm'} = __FILE__ }

package Discovery::Recording {
    use parent -norequire, 'TAP::Harness';

    sub runtests {
        my ( $self, @tests ) = @_;
        my $aggregate = $self->SUPER::runtests(@tests);
        for my $test ( $aggregate->descriptions ) {
            my ($parser) = $aggregate->parsers($test);
            print {$main::RESULT} "$test\t", ( $parser->has_problems ? 'fail' : 'pass' ), "\n";
        }
        return $aggregate;
    }
}

open our $RESULT, '>&', \*STDOUT    or die "result: $!";
open STDOUT,      '>',  '/dev/null' or die "stdout: $!";
open STDERR,      '>',  '/dev/null' or die "stderr: $!";
my $app = App::Prove->new;
$app->process_args( '--harness', 'Discovery::Recording', @ARGV );
exit( $app->run ? 0 : 1 );
PERL

# The verdict of prove on each test, as `prove -l` gives it in the root of the project.
# prove runs the tests in the project itself, so a project whose tests write files goes there as a copy.
sub proves ( $self, @arguments ) {
    return $self->proves_with( '-l', @arguments );
}

# The verdict of prove with the given arguments alone, for a launch without the library switch.
sub proves_with ( $self, @arguments ) {
    my $script = "$self->{scratch}/prove.pl";
    if ( !-e $script ) {
        open my $handle, '>', $script or die "write $script: $!";
        print {$handle} $PROVE or die "write $script: $!";
        close $handle          or die "close $script: $!";
    }
    my $pid = open my $result, q{-|};
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        setpgrp 0, 0;
        chdir $self->{root} or POSIX::_exit(126);

        # A test that reads its standard input waits for a terminal, which the tool never gives it.
        open STDIN, '<', '/dev/null' or POSIX::_exit(126);
        exec {$^X} $^X, $script, @arguments or POSIX::_exit(127);
    }

    # A test may loop under a mutant, and prove waits for it without a limit of its own.
    my @lines = eval {
        local $SIG{ALRM} = sub { die "the time of prove is over\n" };
        alarm $PROVE_SECONDS;
        my @read = readline $result;
        alarm 0;
        @read;
    };
    alarm 0;
    kill 'KILL', -$pid, $pid;
    close $result or 1;
    return { map { /\A(.*)\t(pass|fail)\n\z/ ? ( $1 => $2 ) : () } @lines };
}

sub text ( $self, $path ) {
    open my $handle, '<:raw', "$self->{root}/$path" or return;
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return $text;
}

sub remove ( $self, $path ) {
    _open_up("$self->{root}/$path");
    File::Path::remove_tree("$self->{root}/$path");
    return;
}

# A test may take the rights of a directory away, and a removal needs them back.
sub _open_up ($path) {
    return if !-d $path || -l $path;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if -l $File::Find::name || !-d _;
                chmod oct '700', $File::Find::name or die "chmod $File::Find::name: $!";
            },
        },
        $path,
    );
    return;
}

sub _signature ($path) {
    my @status = lstat $path or return 'gone';
    return 'link ' . readlink $path if -l _;
    my $mode = sprintf '%04o', $status[2] & oct '7777';
    return "directory $mode" if -d _;
    return "other $mode"     if !-f _;
    my $digest = eval { Digest::SHA->new(256)->addfile($path)->hexdigest };
    return "file $mode " . ( defined $digest ? $digest : 'unreadable' );
}

# The kind, the mode, and the content of every entry, apart from the directories that a run may write.
# A size and a time would miss a rewrite that restores both.
sub snapshot ($self) {
    my $root = $self->{root};
    my %state;

    # A test may leave a directory without any right: the directory itself is an entry, and its content stays out of reach.
    no warnings 'File::Find';
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if $File::Find::name eq $root;
                my $path = substr $File::Find::name, 1 + length $root;
                if ( $OUTSIDE{$path} ) {
                    $File::Find::prune = 1;
                    return;
                }
                $state{$path} = _signature($File::Find::name);
                return;
            },
        },
        $root,
    );
    return \%state;
}

sub changes ( $before, $after ) {
    my %seen = ( $before->%*, $after->%* );
    return [
        map {
                !exists $before->{$_}         ? "created $_"
              : !exists $after->{$_}          ? "removed $_"
              : $before->{$_} ne $after->{$_} ? "changed $_"
              : ()
        } sort keys %seen
    ];
}

# A signal to the group of process 0 or 1 reaches processes of other work, so such a name is no registration.
sub _registered ($registry) {
    opendir my $handle, $registry or return {};
    my %label;
    for my $pid ( grep { /\A[0-9]+\z/ && $_ > 1 } readdir $handle ) {
        open my $file, '<', "$registry/$pid" or next;
        my $label = readline $file;
        close $file or die "close: $!";
        chomp( $label = defined $label ? $label : 'a process' );
        $label{$pid} = $label;
    }
    closedir $handle or die "close $registry: $!";
    return \%label;
}

sub _alive ($pid) {
    return kill( 0, $pid ) || $!{EPERM} ? 1 : 0;
}

# The labels of the registered processes that still run, after the time a signalled process needs to end.
sub living ($self) {
    my $label    = _registered( $self->{registry} );
    my $deadline = Time::HiRes::time() + $GRACE_SECONDS;
    my @alive    = grep { _alive($_) } sort keys $label->%*;
    while ( @alive && Time::HiRes::time() < $deadline ) {
        Time::HiRes::sleep(0.05);
        @alive = grep { _alive($_) } @alive;
    }
    return [ sort map { $label->{$_} } @alive ];
}

# No process of a case may outlive it on a shared machine, so every registered process ends here with its group.
sub _reap ($registry) {
    my $label = _registered($registry);
    for my $pid ( sort keys $label->%* ) {
        kill 'KILL', -$pid, $pid if _alive($pid);
        unlink "$registry/$pid";
    }
    return scalar keys $label->%*;
}

sub reap ($self) {
    return _reap( $self->{registry} );
}

sub git ( $self, @arguments ) {
    my @command = (
        'git',                             '-C', $self->{root},          '-c',
        'core.hooksPath=/dev/null',        '-c', 'user.name=Test',       '-c',
        'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', @arguments,
    );
    system(@command) == 0 or die "git @arguments failed\n";
    return;
}

# A child of the harness holds a copy of the list, and the scratch files belong to the process that made them.
sub _discard ($scratch) {
    return if !defined $OWNER{$scratch} || $OWNER{$scratch} != $$;
    delete $OWNER{$scratch};
    _reap("$scratch/registry");
    _open_up($scratch);
    File::Path::remove_tree($scratch);

    # A test of a case may hold a fixed path outside the scratch directory, which carries the name of that directory.
    my ($token) = $scratch =~ m{([^/]+)\z};
    unlink glob "/tmp/$token-*";
    return;
}

sub discard ($self) {
    return _discard( $self->{scratch} );
}

sub DESTROY ($self) {
    local ( $?, $@, $! );    ## no critic (Variables::RequireInitializationForLocalVars)
    eval { $self->discard; 1 } or warn "cannot discard $self->{scratch}: $@";
    return;
}

END {
    my $status = $?;
    for my $scratch ( sort keys %OWNER ) {
        eval { _discard($scratch); 1 } or warn "cannot discard $scratch: $@";
    }
    $? = $status;            ## no critic (Variables::RequireLocalizedPunctuationVars)
}

1;
