package Test::Mutation::Git;
use v5.36;
use Errno           ();
use IO::Select      ();
use POSIX           ();
use Types::Standard qw(ArrayRef HashRef Int Str Tuple);
use Type::Params    qw(signature_for);
use Test::Mutation::Diff;
use Test::Mutation::Error;
use Test::Mutation::Message;

our $VERSION = '0.001';

my $WHOLE_FILE = 2**31;

signature_for changed => (
    positional => [ Str, Str ],
    returns    => HashRef [ ArrayRef [ Tuple [ Int, Int ] ] ],
);

sub changed ( $root, $revision ) {
    my $commit =
      _git( $root, $revision, 'rev-parse', '--verify', '--quiet', '--end-of-options', $revision . '^{commit}' );
    chomp $commit;
    my $diff    = _git( $root, undef, 'diff', '--no-color', '--no-ext-diff', '--relative', '-U0', $commit, q{--} );
    my $changed = Test::Mutation::Diff::changed_lines($diff);
    for my $path ( split /\0/, _git( $root, undef, 'ls-files', '--others', '--exclude-standard', '-z' ) ) {
        $changed->{$path} = [ [ 1, $WHOLE_FILE ] ];
    }
    return $changed;
}

sub _start ( $root, @arguments ) {
    pipe my $output, my $writer or Test::Mutation::Error::raise( 'pipe-unopenable', reason => "$!" );
    pipe my $errors, my $logger or Test::Mutation::Error::raise( 'pipe-unopenable', reason => "$!" );
    my $pid = fork;
    Test::Mutation::Error::raise( 'git-unstartable', reason => "$!" ) if !defined $pid;
    if ( !$pid ) {
        POSIX::dup2( fileno $writer, 1 );
        POSIX::dup2( fileno $logger, 2 );
        no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        exec {'git'} 'git', '--no-optional-locks', '-C', $root, @arguments
          or syswrite $logger, Test::Mutation::Message::text_of( 'git-unstartable', reason => "$!" ) . "\n";
        POSIX::_exit(127);
    }
    return ( $pid, $output, $errors );
}

sub _receive ( $streams, $bytes, $stream ) {
    my $count = sysread $stream, my $chunk, 65_536;
    if ( !defined $count ) {
        return if $! == Errno::EINTR();
        $bytes->{error} = "$!";
    }
    if ($count) {
        $bytes->{$stream} .= $chunk;
    }
    else {
        $streams->remove($stream);
    }
    return;
}

# The child owns the write ends of both pipes after startup, and the parent drains them until EOF.
sub _git ( $root, $revision, @arguments ) {
    my ( $pid, $output, $errors ) = _start( $root, @arguments );
    my $streams = IO::Select->new( $output, $errors );
    my %bytes   = ( $output => q{}, $errors => q{} );
    while ( $streams->count ) {
        _receive( $streams, \%bytes, $_ ) for $streams->can_read;
    }
    while ( waitpid( $pid, 0 ) == -1 ) {
        Test::Mutation::Error::raise( 'git-failed', command => $arguments[0], reason => "$!" ) if $! != Errno::EINTR();
    }
    my $status = $?;
    Test::Mutation::Error::raise( 'git-failed', command => $arguments[0], reason => $bytes{error} )
      if exists $bytes{error};
    return $bytes{$output} if !$status;
    Test::Mutation::Error::raise( 'revision-unknown', revision => $revision )
      if defined $revision && $status == 256;
    my $command  = $arguments[0];
    my ($reason) = split /\n/, $bytes{$errors};
    Test::Mutation::Error::raise( 'git-silent', command => $command ) if !defined $reason;
    return Test::Mutation::Error::raise( 'git-failed', command => $command, reason => $reason );
}

1;

__END__

=head1 NAME

Test::Mutation::Git - ask Git which lines changed

=head1 SYNOPSIS

    my $changed = Test::Mutation::Git::changed( $root, 'origin/main' );

=head1 FUNCTIONS

=head2 changed

Returns, for each file under C<$root>, the line ranges that differ from the revision.
A file that Git does not track counts as changed from its first line to its last.
An unknown revision raises a usage error that names the revision.
An operational failure raises an environment error with the first line of the Git diagnostic.

=cut
