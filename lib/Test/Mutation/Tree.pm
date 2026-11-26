package Test::Mutation::Tree;
use v5.36;
use Digest::SHA     ();
use File::Basename  ();
use File::Copy      ();
use File::Find      ();
use List::Util      ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef HashRef Int Optional Slurpy Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Signals;

our $VERSION = '0.001';

my @LETTERS        = ( 'a' .. 'z', 'A' .. 'Z', 0 .. 9 );
my $NAME_LENGTH    = 6;
my $NAME_TRIES     = 20;
my $RECENT_SECONDS = 2;

signature_for make => ( positional => [ Slurpy [ ArrayRef [Str] ] ], returns => Int );

sub make ($paths) {
    return List::Util::sum0( map { _make($_) } $paths->@* );
}

sub _make ($path) {
    return 0 if -d $path;
    my $made = _make( File::Basename::dirname($path) );
    mkdir $path or Test::Mutation::Error::raise( 'directory-uncreatable', path => $path, reason => "$!" );
    return $made + 1;
}

signature_for temporary => ( positional => [ Str, Str ], returns => Str );

sub temporary ( $parent, $prefix ) {
    my @candidates =
      map {
        "$parent/$prefix" . join q{},
          map { $LETTERS[ rand @LETTERS ] }
          1 .. $NAME_LENGTH
      } 1 .. $NAME_TRIES;

    # A name that another process took a moment ago is no failure, so the next candidate has its turn.
    my $made = List::Util::first { mkdir $_, oct '700' } @candidates;
    Test::Mutation::Error::raise( 'directory-uncreatable', path => $candidates[-1], reason => "$!" ) if !defined $made;
    return $made;
}

signature_for snapshot => (
    named   => [ root => Str, skip => ArrayRef [Str] ],
    returns => HashRef [Str],
);

sub snapshot ($arg) {
    my $root   = $arg->root;
    my $recent = Time::HiRes::time() - $RECENT_SECONDS;
    my %skip   = map { $_ => 1 } $arg->skip->@*;
    my %state;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if $File::Find::name eq $root;
                my $path = substr $File::Find::name, 1 + length $root;
                if ( $skip{$path} ) {
                    $File::Find::prune = 1;
                    return;
                }
                $state{$path} = _signature( $File::Find::name, $recent );
                return;
            },
        },
        $root,
    );
    return \%state;
}

sub _signature ( $path, $recent ) {
    my @status = Time::HiRes::lstat($path) or return 'gone';
    return "link $status[1] " . readlink $path if -l _;
    my $mode = sprintf '%04o', $status[2] & oct '7777';
    return "directory $mode $status[1]" if -d _;
    my $identity = join q{ }, 'file', $mode, @status[ 0, 1, 7, 9, 10 ];
    return $identity if !-f _ || $status[9] < $recent && $status[10] < $recent;
    return $identity unless open my $file, '<:raw', $path;
    my $digest = Digest::SHA->new(256)->addfile($file)->hexdigest;
    close $file or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return join "\0", $identity, $digest;
}

sub _changed ( $before, $after ) {
    return 0 if $before eq $after;
    my ( $old, $first ) = split /\0/, $before, 2;
    my ( $new, $last )  = split /\0/, $after,  2;
    return $old ne $new || defined $first && defined $last && $first ne $last;
}

signature_for changes => ( positional => [ HashRef [Str], HashRef [Str] ], returns => ArrayRef [Str] );

sub changes ( $before, $after ) {
    my %seen  = ( $before->%*, $after->%* );
    my @lines = map {
            !exists $before->{$_}                   ? "created $_"
          : !exists $after->{$_}                    ? "removed $_"
          : _changed( $before->{$_}, $after->{$_} ) ? "changed $_"
          : ()
    } sort keys %seen;
    return \@lines;
}

signature_for copy => (
    named =>
      [ from => Str, to => Str, skip => ArrayRef [Str], link => ArrayRef [Str], state => Optional [ HashRef [Str] ] ],
    returns => Int,
);

sub copy ($arg) {
    my ( $from, $to ) = ( $arg->from, $arg->to );
    Test::Mutation::Error::raise( 'directory-missing', path => $from ) if !-d $from;
    my %skip = map { $_ => 1 } $arg->skip->@*;
    my %link = map { $_ => 1 } $arg->link->@*;
    make($to);
    my ( $count, %directory ) = (0);
    my $state  = $arg->state;
    my $recent = Time::HiRes::time() - $RECENT_SECONDS;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if $File::Find::name eq $from;

                # The copy of a large tree takes its time, so a signal ends the work between two paths.
                Test::Mutation::Signals::check();
                my $path = substr $File::Find::name, 1 + length $from;
                if ( $skip{$path} || $link{$path} ) {
                    $File::Find::prune = 1;
                    return if $skip{$path};
                    symlink $File::Find::name, "$to/$path"
                      or Test::Mutation::Error::raise( 'file-unlinkable', path => "$to/$path", reason => "$!" );
                    $state->{$path} = _signature( "$to/$path", $recent ) if $state;
                    return;
                }
                my $kind = _copy_node( $File::Find::name, "$to/$path" );
                $count++ if length $kind;
                $directory{$path} = 1                                if $kind eq q{directory};
                $state->{$path} = _signature( "$to/$path", $recent ) if $state && length $kind && $kind ne q{directory};
                return;
            },
        },
        $from,
    );

    # A directory may forbid new entries, so each one gets its mode after its content.
    for my $path ( sort keys %directory ) {
        _copy_mode( "$from/$path", "$to/$path" );
        $state->{$path} = _signature( "$to/$path", $recent ) if $state;
    }
    return $count;
}

# Copies one file, directory, or link without the content of a directory, and returns its kind.
# A pipe, a socket, or a device has no kind and stays out.
sub _copy_node ( $source, $target ) {
    my @status = Time::HiRes::lstat($source)
      or Test::Mutation::Error::raise( 'file-unreadable', path => $source, reason => "$!" );
    if ( -l _ ) {
        symlink readlink($source), $target
          or Test::Mutation::Error::raise( 'file-unlinkable', path => $target, reason => "$!" );
        return q{link};
    }
    if ( -d _ ) {
        mkdir $target or Test::Mutation::Error::raise( 'directory-uncreatable', path => $target, reason => "$!" );
        return q{directory};
    }
    return q{} if !-f _;
    File::Copy::copy( $source, $target )
      or Test::Mutation::Error::raise( 'file-uncopyable', source => $source, target => $target, reason => "$!" );
    _copy_mode( $source, $target );
    Time::HiRes::utime( $status[8], $status[9], $target )
      or Test::Mutation::Error::raise( 'file-time-unsettable', path => $target, reason => "$!" );
    return q{file};
}

sub _is_directory ($path) {
    return -d $path && !-l $path ? 1 : 0;
}

sub _copy_mode ( $source, $target ) {
    my $mode = ( stat $source )[2];
    chmod $mode & oct '7777', $target
      or Test::Mutation::Error::raise( 'file-mode-unsettable', path => $target, reason => "$!" );
    return;
}

sub _below ( $path, $closed ) {
    while ( $path =~ s{/[^/]+\z}{} ) {
        return 1 if $closed->{$path};
    }
    return 0;
}

signature_for restore => (
    named   => [ from => Str, to => Str, changes => ArrayRef [Str], state => Optional [ HashRef [Str] ] ],
    returns => Int,
);

sub restore ($arg) {
    my ( $from, $to ) = ( $arg->from, $arg->to );

    # A directory sorts before its content, so a removed directory returns before its files.
    my @paths = sort map { s/\A\w+[ ]//r } $arg->changes->@*;
    my ( %directory, %closed );
    for my $path (@paths) {
        my ( $source, $target ) = ( "$from/$path", "$to/$path" );

        # A path below a file, a link, or a gap of the source went with that path, and a link there leads elsewhere.
        next               if _below( $path, \%closed );
        $closed{$path} = 1 if !_is_directory($source);
        if ( _is_directory($source) && _is_directory($target) ) {

            # A directory that stays may forbid new entries, so its own mode waits for its content.
            chmod oct q{700}, $target
              or Test::Mutation::Error::raise( 'directory-unopenable', path => $target, reason => "$!" );
        }
        else {
            remove($target);
            next if !-e $source && !-l $source;
            next if _copy_node( $source, $target ) ne q{directory};
        }
        $directory{$path} = 1;
    }
    _copy_mode( "$from/$_", "$to/$_" ) for sort keys %directory;
    if ( my $state = $arg->state ) {
        my $recent = Time::HiRes::time() - $RECENT_SECONDS;
        $state->{$_} = _signature( "$to/$_", $recent ) for grep { exists $state->{$_} } @paths;
    }
    return scalar @paths;
}

# The handle of the directory closes with the call, so a deep tree holds no handle open for each level.
sub _names ($path) {
    opendir my $handle, $path or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    return grep { $_ ne q{.} && $_ ne q{..} } readdir $handle;
}

signature_for remove => ( positional => [Str], returns => Int );

sub remove ($path) {
    if ( _is_directory($path) ) {

        # A test may take the rights of a directory away, and its content is out of reach without them.
        chmod oct q{700}, $path
          or Test::Mutation::Error::raise( 'directory-unopenable', path => $path, reason => "$!" );
        my $count = 1;
        $count += remove("$path/$_") for _names($path);
        rmdir $path or Test::Mutation::Error::raise( 'file-unremovable', path => $path, reason => "$!" );
        return $count;
    }
    return 0 if !-e $path && !-l $path;
    unlink $path or Test::Mutation::Error::raise( 'file-unremovable', path => $path, reason => "$!" );
    return 1;
}

1;

__END__

=head1 NAME

Test::Mutation::Tree - copy the files of a project and tell whether they changed

=head1 SYNOPSIS

    my $before = Test::Mutation::Tree::snapshot( root => $root, skip => [ '.git', '.mutation' ] );
    ...
    my $changes = Test::Mutation::Tree::changes( $before, Test::Mutation::Tree::snapshot( root => $root, skip => [ '.git', '.mutation' ] ) );

    Test::Mutation::Tree::copy( from => $root, to => $copy, skip => ['.git'], link => ['local'] );
    Test::Mutation::Tree::restore( from => $root, to => $copy, changes => $changes );

=head1 DESCRIPTION

A mutant runs with the rights of the tests, so it may create, change, or remove a file of the project.
The run compares the state of a tree before and after a mutant to find such a change.
The tests run in copies of the project, and a changed copy returns to the state of its source.

Every function dies with a L<Test::Mutation::Error> of the kind C<environment> when the system refuses a step.

=head1 FUNCTIONS

=head2 make

    my $made = Test::Mutation::Tree::make( "$root/.mutation", "$root/mutation-report" );

Creates each directory with every parent that it lacks, and returns the number of new directories.

=head2 temporary

    my $work = Test::Mutation::Tree::temporary( "$root/.mutation", 'run-' );

Creates a new directory below the parent and returns its path.
Its name is the prefix and six letters that no other entry has, and its owner alone may enter it.

=head2 snapshot

Returns a signature for every file, directory, and link below C<root>, keyed by its path from the root.
A path in C<skip> is left out with all it holds.
File signatures include the device, inode, mode, size, modification time, and change time.
The run also hashes readable regular files modified or changed within two seconds of a snapshot.
Directory signatures include their mode and inode.

=head2 changes

Compares two states and returns one line for each path that was created, removed, or changed, in the order of the paths.

=head2 copy

Copies the tree below C<from> into the new directory C<to> and returns the number of copied paths.
A file keeps its mode and its times, a link stays a link, and a pipe or a socket is left out.
A path in C<skip> is left out with all it holds, and a path in C<link> becomes a link to the original.

=head2 restore

Returns the paths that C<changes> names in the tree C<to> to their state in the tree C<from>, and returns their number.
C<changes> takes the lines of the function C<changes>.

=head2 remove

Removes a file, a link, or a directory with all it holds, and returns the number of removed paths.
A directory without any right for its owner is removed too, and the target of a link stays.

=cut
