package Permutl::Tree;
use v5.36;
use File::Copy      ();
use File::Find      ();
use File::Path      ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef HashRef Int Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

signature_for snapshot => (
    named   => [ root => Str, skip => ArrayRef [Str] ],
    returns => HashRef [Str],
);

sub snapshot ($arg) {
    my $root = $arg->root;
    my %skip = map { $_ => 1 } $arg->skip->@*;
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
                $state{$path} = _signature($File::Find::name);
                return;
            },
        },
        $root,
    );
    return \%state;
}

# The size and the time of a file stand for its content, which keeps the walk of a large tree short.
sub _signature ($path) {
    my @status = Time::HiRes::lstat($path) or return 'gone';
    return 'link ' . readlink $path if -l _;
    my $mode = sprintf '%04o', $status[2] & oct '7777';
    return "directory $mode" if -d _;
    return "file $status[7] $status[9] $mode";
}

signature_for changes => ( positional => [ HashRef [Str], HashRef [Str] ], returns => ArrayRef [Str] );

sub changes ( $before, $after ) {
    my %seen  = ( $before->%*, $after->%* );
    my @lines = map {
            !exists $before->{$_}         ? "created $_"
          : !exists $after->{$_}          ? "removed $_"
          : $before->{$_} ne $after->{$_} ? "changed $_"
          : ()
    } sort keys %seen;
    return \@lines;
}

signature_for copy => (
    named   => [ from => Str, to => Str, skip => ArrayRef [Str], link => ArrayRef [Str] ],
    returns => Int,
);

sub copy ($arg) {
    my ( $from, $to ) = ( $arg->from, $arg->to );
    die "cannot read $from: no such directory\n" if !-d $from;
    my %skip = map { $_ => 1 } $arg->skip->@*;
    my %link = map { $_ => 1 } $arg->link->@*;
    File::Path::make_path($to);
    my ( $count, %directory ) = (0);
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if $File::Find::name eq $from;
                my $path = substr $File::Find::name, 1 + length $from;
                if ( $skip{$path} || $link{$path} ) {
                    $File::Find::prune = 1;
                    return if $skip{$path};
                    symlink $File::Find::name, "$to/$path" or die "cannot link $to/$path: $!\n";
                    return;
                }
                my $kind = _copy_node( $File::Find::name, "$to/$path" );
                $count++              if length $kind;
                $directory{$path} = 1 if $kind eq q{directory};
                return;
            },
        },
        $from,
    );

    # A directory may forbid new entries, so each one gets its mode after its content.
    _copy_mode( "$from/$_", "$to/$_" ) for sort keys %directory;
    return $count;
}

# Copies one file, directory, or link without the content of a directory, and returns its kind.
# A pipe, a socket, or a device has no kind and stays out.
sub _copy_node ( $source, $target ) {
    my @status = Time::HiRes::lstat($source) or die "cannot read $source: $!\n";
    if ( -l _ ) {
        symlink readlink($source), $target or die "cannot link $target: $!\n";
        return q{link};
    }
    if ( -d _ ) {
        mkdir $target or die "cannot create $target: $!\n";
        return q{directory};
    }
    return q{} if !-f _;
    File::Copy::copy( $source, $target ) or die "cannot copy $source to $target: $!\n";
    _copy_mode( $source, $target );
    Time::HiRes::utime( $status[8], $status[9], $target ) or die "cannot set the time of $target: $!\n";
    return q{file};
}

sub _is_directory ($path) {
    return -d $path && !-l $path ? 1 : 0;
}

sub _copy_mode ( $source, $target ) {
    my $mode = ( stat $source )[2];
    chmod $mode & oct '7777', $target or die "cannot set the mode of $target: $!\n";
    return;
}

signature_for restore => (
    named   => [ from => Str, to => Str, changes => ArrayRef [Str] ],
    returns => Int,
);

sub restore ($arg) {
    my ( $from, $to ) = ( $arg->from, $arg->to );

    # A directory sorts before its content, so a removed directory returns before its files.
    my @paths = sort map { s/\A\w+[ ]//r } $arg->changes->@*;
    my %directory;
    for my $path (@paths) {
        my ( $source, $target ) = ( "$from/$path", "$to/$path" );
        if ( _is_directory($source) && _is_directory($target) ) {

            # A directory that stays may forbid new entries, so its own mode waits for its content.
            chmod oct q{700}, $target or die "cannot open $target: $!\n";
        }
        else {
            remove($target);
            next if !-e $source && !-l $source;
            next if _copy_node( $source, $target ) ne q{directory};
        }
        $directory{$path} = 1;
    }
    _copy_mode( "$from/$_", "$to/$_" ) for sort keys %directory;
    return scalar @paths;
}

# The handle of the directory closes with the call, so a deep tree holds no handle open for each level.
sub _names ($path) {
    opendir my $handle, $path or die "cannot read $path: $!\n";
    return grep { $_ ne q{.} && $_ ne q{..} } readdir $handle;
}

signature_for remove => ( positional => [Str], returns => Int );

sub remove ($path) {
    if ( _is_directory($path) ) {

        # A test may take the rights of a directory away, and its content is out of reach without them.
        chmod oct q{700}, $path or die "cannot open $path: $!\n";
        my $count = 1;
        $count += remove("$path/$_") for _names($path);
        rmdir $path or die "cannot remove $path: $!\n";
        return $count;
    }
    return 0 if !-e $path && !-l $path;
    unlink $path or die "cannot remove $path: $!\n";
    return 1;
}

1;

__END__

=head1 NAME

Permutl::Tree - copy the files of a project and tell whether they changed

=head1 SYNOPSIS

    my $before = Permutl::Tree::snapshot( root => $root, skip => [ '.git', '.permutl' ] );
    ...
    my $changes = Permutl::Tree::changes( $before, Permutl::Tree::snapshot( root => $root, skip => [ '.git', '.permutl' ] ) );

    Permutl::Tree::copy( from => $root, to => $copy, skip => ['.git'], link => ['local'] );
    Permutl::Tree::restore( from => $root, to => $copy, changes => $changes );

=head1 DESCRIPTION

A mutant runs with the rights of the tests, so it may create, change, or remove a file of the project.
The run compares the state of a tree before and after a mutant to find such a change.
The tests run in copies of the project, and a changed copy returns to the state of its source.

=head1 FUNCTIONS

=head2 snapshot

Returns a signature for every file, directory, and link below C<root>, keyed by its path from the root.
A path in C<skip> is left out with all it holds.
The signature of a file holds its size, its modification time, and its mode, and no digest of its content.
The signature of a directory holds its mode.

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
