package Test::Mutation::Git;
use v5.36;
use File::Temp      ();
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
    my $diff    = _git( $root, 'diff', '--no-color', '--no-ext-diff', '--relative', '-U0', $revision, q{--} );
    my $changed = Test::Mutation::Diff::changed_lines($diff);
    for my $path ( split /\0/, _git( $root, 'ls-files', '--others', '--exclude-standard', '-z' ) ) {
        $changed->{$path} = [ [ 1, $WHOLE_FILE ] ];
    }
    return $changed;
}

# Git writes its answer and its errors to files, and the call reads one of them when Git has ended.
# A fork of its own fails with a reason, where the fork of a piped open dies or waits until a process is free.
sub _git ( $root, @arguments ) {
    my ( $output, $errors ) = ( File::Temp->new, File::Temp->new );
    my $pid = fork;
    Test::Mutation::Error::raise( 'git-unstartable', reason => "$!" ) if !defined $pid;
    if ( !$pid ) {

        # The child must end here: an exception would run the rest of the caller in a second process.
        POSIX::dup2( fileno $output, 1 );
        POSIX::dup2( fileno $errors, 2 );
        no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        exec {'git'} 'git', '-C', $root, @arguments
          or syswrite $errors, Test::Mutation::Message::text_of( 'git-unstartable', reason => "$!" ) . "\n";
        POSIX::_exit(127);
    }
    waitpid $pid, 0;
    my $failed = $?;

    # The child wrote through the same open files, so the call reads one of them from its start.
    my $answer = $failed ? $errors : $output;
    seek $answer, 0, 0
      or Test::Mutation::Error::raise( 'file-unreadable', path => $answer->filename, reason => "$!" );
    my $text = do { local $/ = undef; readline $answer };
    return defined $text ? $text : q{} if !$failed;

    my $command  = $arguments[0];
    my ($reason) = split /\n/, defined $text ? $text : q{};
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
The function dies with a L<Test::Mutation::Error> of the kind C<environment> when Git fails, and its message holds the first line of the Git error.

=cut
