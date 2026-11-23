use v5.36;
use Test2::V0;
use File::Path ();
use File::Temp ();
use Permutl::Tree;

sub tree (%files) {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    for my $path ( sort keys %files ) {
        my ($directory) = "$root/$path" =~ m{\A(.*)/};
        File::Path::make_path($directory);
        open my $handle, '>', "$root/$path" or die "write $path: $!";
        print {$handle} $files{$path} or die "write $path: $!";
        close $handle                 or die "close $path: $!";
    }
    return $root;
}

sub snapshot ( $root, @skip ) {
    return Permutl::Tree::snapshot( root => $root, skip => \@skip );
}

subtest 'the state names every file, directory, and link below the root' => sub {
    my $root = tree( 'lib/A.pm' => "1;\n", 't/a.t' => 'ok', '.permutl/run/x' => 'work', '.git/HEAD' => 'ref' );
    mkdir "$root/empty" or die "mkdir: $!";
    symlink 'lib/A.pm', "$root/link" or die "symlink: $!";
    is [ sort keys snapshot($root)->%* ],
      [
        '.git', '.git/HEAD', '.permutl', '.permutl/run', '.permutl/run/x', 'empty',
        'lib',  'lib/A.pm',  'link',     't',            't/a.t'
      ],
      'paths from the root, hidden ones included';
    is [ sort keys snapshot( $root, '.git', '.permutl' )->%* ], [ 'empty', 'lib', 'lib/A.pm', 'link', 't', 't/a.t' ],
      'a skipped directory is left out with all it holds';
    is [ sort keys snapshot( $root, 'lib/A.pm', 't' )->%* ],
      [ '.git', '.git/HEAD', '.permutl', '.permutl/run', '.permutl/run/x', 'empty', 'lib', 'link' ],
      'a skipped path may lie below the top';
};

subtest 'changes names what was created, removed, and changed' => sub {
    my $root =
      tree( 'lib/A.pm' => "1;\n", 'data/kept.txt' => 'kept', 'data/gone.txt' => 'gone', 'data/grown.txt' => 'a' );
    my $before = snapshot($root);
    is Permutl::Tree::changes( $before, snapshot($root) ), [], 'an untouched tree has no change';

    unlink "$root/data/gone.txt" or die "unlink: $!";
    tree_file( "$root/data/grown.txt", 'longer text' );
    tree_file( "$root/stray",          q{} );
    mkdir "$root/made" or die "mkdir: $!";
    is Permutl::Tree::changes( $before, snapshot($root) ),
      [ 'removed data/gone.txt', 'changed data/grown.txt', 'created made', 'created stray' ],
      'one line for each path, in the order of the paths';
};

sub tree_file ( $path, $text ) {
    open my $handle, '>', $path or die "write $path: $!";
    print {$handle} $text or die "write $path: $!";
    close $handle         or die "close $path: $!";
    return;
}

subtest 'a file with new content of the same size counts by its time' => sub {
    my $root   = tree( 'data.txt' => 'first' );
    my $before = snapshot($root);
    tree_file( "$root/data.txt", 'other' );
    utime 1_000_000_000, 1_000_000_000, "$root/data.txt" or die "utime: $!";
    is Permutl::Tree::changes( $before, snapshot($root) ), ['changed data.txt'],
      'another modification time is a change';
};

subtest 'a path that changes its kind is a change' => sub {
    my $root   = tree( 'thing' => 'a file' );
    my $before = snapshot($root);
    unlink "$root/thing" or die "unlink: $!";
    mkdir "$root/thing"  or die "mkdir: $!";
    is Permutl::Tree::changes( $before, snapshot($root) ), ['changed thing'], 'a file that became a directory';

    my $linked = tree( 'target' => 'x' );
    symlink 'target', "$linked/link" or die "symlink: $!";
    my $earlier = snapshot($linked);
    unlink "$linked/link" or die "unlink: $!";
    symlink 'elsewhere', "$linked/link" or die "symlink: $!";
    is Permutl::Tree::changes( $earlier, snapshot($linked) ), ['changed link'], 'a link with another target';
};

like dies { Permutl::Tree::snapshot( root => 1 ) }, qr/Wrong number of parameters/,   'snapshot checks its arguments';
like dies { Permutl::Tree::changes( {}, [] ) },     qr/did not pass type constraint/, 'changes checks its arguments';

done_testing;
