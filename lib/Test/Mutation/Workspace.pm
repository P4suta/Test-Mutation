package Test::Mutation::Workspace;
use v5.36;
use Moo;
use Cwd             ();
use Fcntl           qw(:DEFAULT :flock);
use File::Spec      ();
use Types::Standard qw(Bool FileHandle InstanceOf Int Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Tree;
use Test::Mutation::Try;
use Test::Mutation::Workspace::Processes;

our $VERSION = '0.001';

with 'Test::Mutation::Value';

my $MARKER = "Test::Mutation workspace\n";
has directory => ( is => 'ro', isa => Str,        required => 1 );
has _lock     => ( is => 'ro', isa => FileHandle, required => 1 );
has _pid      => ( is => 'ro', isa => Int,        default  => sub { $$ } );

signature_for acquire => ( positional => [Str], returns => InstanceOf [__PACKAGE__] );

sub acquire ($project) {
    my $parent = _temporary_parent($project);
    _reclaim($parent);
    my $directory = Test::Mutation::Tree::temporary( $parent, 'mutation-' );
    my $prepared  = Test::Mutation::Try::attempt(
        sub {
            my $path = "$directory/owner";
            sysopen my $lock, $path, O_RDWR | O_CREAT | O_EXCL, oct '600'
              or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
            flock $lock, LOCK_EX
              or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
            my $written = syswrite $lock, $MARKER;
            Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" )
              if !defined $written || $written != length $MARKER;
            Test::Mutation::Tree::make( map { "$directory/$_" } qw(tree slot work) );
            my $lease = "$directory/processes";
            sysopen my $file, $lease, O_WRONLY | O_CREAT | O_EXCL, oct '600'
              or Test::Mutation::Error::raise( 'file-unwritable', path => $lease, reason => "$!" );
            close $file or Test::Mutation::Error::raise( 'file-unclosable', path => $lease, reason => "$!" );
            return __PACKAGE__->new( directory => $directory, _lock => $lock );
        },
        'interruption'
    );
    return $prepared->{value} if exists $prepared->{value};
    Test::Mutation::Tree::remove($directory);
    die $prepared->{error};    ## no critic (ErrorHandling::RequireCarping)
}

sub _temporary_parent ($project) {
    my $root     = Cwd::abs_path($project);
    my $selected = File::Spec->tmpdir;
    local %ENV = %ENV;
    delete @ENV{qw(TMPDIR TMP TEMP)};
    for my $candidate ( $selected, File::Spec->tmpdir ) {
        my $path     = Cwd::abs_path($candidate) or next;
        my $relative = File::Spec->abs2rel( $path, $root );
        return $path if $relative =~ m{\A\.\.(?:/|\z)};
    }
    return Test::Mutation::Error::raise(
        'directory-uncreatable',
        path   => $selected,
        reason => 'no temporary directory outside the project'
    );
}

sub _reclaim ($parent) {
    opendir my $entries, $parent
      or Test::Mutation::Error::raise( 'file-unreadable', path => $parent, reason => "$!" );
    my @names = grep { /\Amutation-[A-Za-z0-9]{6}\z/ } readdir $entries;
    closedir $entries or Test::Mutation::Error::raise( 'file-unclosable', path => $parent, reason => "$!" );
    _reclaim_directory("$parent/$_") for @names;
    return;
}

sub _reclaim_directory ($directory) {
    return unless -o $directory;
    return if -l $directory;
    my $path = "$directory/owner";
    return unless sysopen my $lock, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK;
    return unless -f $lock;
    return unless -o $lock;
    return unless flock $lock, LOCK_EX | LOCK_NB;
    my $read = sysread $lock, my $marker, 1 + length $MARKER;
    return unless defined $read && $marker eq $MARKER;
    my @current = lstat $path;
    my @locked  = stat $lock;
    return unless @current && join( q{:}, @current[ 0, 1 ] ) eq join( q{:}, @locked[ 0, 1 ] );
    my $lease = "$directory/processes";
    return if -e $lease && !Test::Mutation::Workspace::Processes::finish($lease);
    Test::Mutation::Tree::remove($directory);
    return;
}

signature_for release => ( method => InstanceOf [__PACKAGE__], positional => [Bool], returns => Bool );

sub release ( $self, $keep ) {
    return 0 if $$ != $self->_pid;
    my $lock = $self->_lock;
    return 1 if !defined fileno $lock;
    my $directory = $self->directory;
    return 0 unless Test::Mutation::Workspace::Processes::finish("$directory/processes");
    my $attempt = Test::Mutation::Try::attempt(
        sub {
            return Test::Mutation::Tree::remove($directory) unless $keep;
            return rename( "$directory/owner", "$directory/kept" )
              || Test::Mutation::Error::raise( 'file-unrenamable', path => "$directory/owner", reason => "$!" );
        }
    );
    close $lock or Test::Mutation::Error::raise( 'file-unclosable', path => "$directory/owner", reason => "$!" );
    return exists $attempt->{value} ? 1 : 0;
}

1;

__END__

=head1 NAME

Test::Mutation::Workspace - own the temporary files of a measurement

=head1 SYNOPSIS

    my $workspace = Test::Mutation::Workspace::acquire($project);
    my $tree = $workspace->directory . '/tree';
    $workspace->release(0);

=head1 DESCRIPTION

Each run holds a private directory with an exclusive lock.
Its reference tree, job slots, and task files share one lifetime.

=head1 FUNCTIONS

=head2 acquire

Creates a workspace outside the project and reclaims previously abandoned workspaces in the same temporary parent.

=head2 directory

Returns the absolute path containing C<tree>, C<slot>, and C<work>.

=head2 release

The acquiring process removes the workspace, or retains it when the argument is true.
Returns true on success.

=cut
