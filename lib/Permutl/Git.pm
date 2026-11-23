package Permutl::Git;
use v5.36;
use File::Temp      ();
use POSIX           ();
use Types::Standard qw(ArrayRef HashRef Int Str Tuple);
use Type::Params    qw(signature_for);
use Permutl::Diff;

our $VERSION = '0.001';

my $WHOLE_FILE = 2**31;

signature_for changed => (
    positional => [ Str, Str ],
    returns    => HashRef [ ArrayRef [ Tuple [ Int, Int ] ] ],
);

sub changed ( $root, $revision ) {
    my $diff    = _git( $root, 'diff', '--no-color', '--no-ext-diff', '--relative', '-U0', $revision, q{--} );
    my $changed = Permutl::Diff::changed_lines($diff);
    for my $path ( split /\0/, _git( $root, 'ls-files', '--others', '--exclude-standard', '-z' ) ) {
        $changed->{$path} = [ [ 1, $WHOLE_FILE ] ];
    }
    return $changed;
}

sub _git ( $root, @arguments ) {
    my $errors = File::Temp->new;
    my $pid    = open my $output, q{-|};    ## no critic (InputOutput::RequireBriefOpen)
    die "cannot start git: $!\n" if !defined $pid;
    if ( !$pid ) {

        # The child must end here: an exception would run the rest of the caller in a second process.
        if ( open my $log, '>', $errors->filename ) {    ## no critic (InputOutput::RequireBriefOpen)
            POSIX::dup2( fileno $log, 2 );
            no warnings 'exec';                          ## no critic (TestingAndDebugging::ProhibitNoWarnings)
            exec {'git'} 'git', '-C', $root, @arguments or syswrite $log, "cannot start git: $!\n";
        }
        POSIX::_exit(127);
    }
    my $text = do { local $/ = undef; readline $output };
    return defined $text ? $text : q{} if close $output;

    open my $handle, '<', $errors->filename or die "git $arguments[0] failed\n";
    my $reason = readline $handle;
    close $handle or die "git $arguments[0] failed\n";
    chomp $reason if defined $reason;
    die 'git ' . $arguments[0] . ' failed: ' . ( defined $reason ? $reason : 'no message' ) . "\n";
}

1;

__END__

=head1 NAME

Permutl::Git - ask Git which lines changed

=head1 SYNOPSIS

    my $changed = Permutl::Git::changed( $root, 'origin/main' );

=head1 FUNCTIONS

=head2 changed

Returns, for each file under C<$root>, the line ranges that differ from the revision.
A file that Git does not track counts as changed from its first line to its last.
The function dies with the first line of the Git error when Git fails.

=cut
