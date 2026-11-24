package Discovery::Project;
use v5.36;
use Cwd         ();
use Digest::SHA ();
use File::Find  ();
use File::Path  ();
use File::Temp  ();
use Time::HiRes ();

# A generated project stands in a scratch directory of its own, next to the registry of the processes its tests start.
# The scratch directory holds every file of a case, so one removal ends the case.

my $GRACE_SECONDS = 2;
my %OUTSIDE       = map { $_ => 1 } '.mutation', 'mutation-report';
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
    return $target;
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
