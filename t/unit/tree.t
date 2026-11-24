use v5.36;
use Test2::V0;
use File::Path ();
use File::Temp ();
use List::Util ();
use lib 't/lib';
use Capability;
use Raised;
use Test::Mutation::Signals;
use Test::Mutation::Tree;

# The modes of the trees below follow from one mask, whatever mask the caller of the test has.
umask oct '022';

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
    return Test::Mutation::Tree::snapshot( root => $root, skip => \@skip );
}

subtest 'the state names every file, directory, and link below the root' => sub {
    my $root = tree( 'lib/A.pm' => "1;\n", 't/a.t' => 'ok', '.mutation/run/x' => 'work', '.git/HEAD' => 'ref' );
    mkdir "$root/empty" or die "mkdir: $!";
    symlink 'lib/A.pm', "$root/link" or die "symlink: $!";
    is [ sort keys snapshot($root)->%* ],
      [
        '.git', '.git/HEAD', '.mutation', '.mutation/run', '.mutation/run/x', 'empty',
        'lib',  'lib/A.pm',  'link',      't',             't/a.t'
      ],
      'paths from the root, hidden ones included';
    is [ sort keys snapshot( $root, '.git', '.mutation' )->%* ], [ 'empty', 'lib', 'lib/A.pm', 'link', 't', 't/a.t' ],
      'a skipped directory is left out with all it holds';
    is [ sort keys snapshot( $root, 'lib/A.pm', 't' )->%* ],
      [ '.git', '.git/HEAD', '.mutation', '.mutation/run', '.mutation/run/x', 'empty', 'lib', 'link' ],
      'a skipped path may lie below the top';
};

subtest 'changes names what was created, removed, and changed' => sub {
    my $root =
      tree( 'lib/A.pm' => "1;\n", 'data/kept.txt' => 'kept', 'data/gone.txt' => 'gone', 'data/grown.txt' => 'a' );
    my $before = snapshot($root);
    is Test::Mutation::Tree::changes( $before, snapshot($root) ), [], 'an untouched tree has no change';

    unlink "$root/data/gone.txt" or die "unlink: $!";
    tree_file( "$root/data/grown.txt", 'longer text' );
    tree_file( "$root/stray",          q{} );
    mkdir "$root/made" or die "mkdir: $!";
    is Test::Mutation::Tree::changes( $before, snapshot($root) ),
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
    is Test::Mutation::Tree::changes( $before, snapshot($root) ), ['changed data.txt'],
      'another modification time is a change';
};

subtest 'another mode of a file or a directory is a change' => sub {
    my $root = tree( 'bin/tool' => "#!perl\n", 'data/list.txt' => 'a' );
    chmod oct '644', "$root/bin/tool" or die "chmod: $!";
    chmod oct '755', "$root/data"     or die "chmod: $!";
    my $before = snapshot($root);
    chmod oct '755', "$root/bin/tool" or die "chmod: $!";
    chmod oct '700', "$root/data"     or die "chmod: $!";
    is Test::Mutation::Tree::changes( $before, snapshot($root) ), [ 'changed bin/tool', 'changed data' ],
      'a file that may run now and a directory that others may not read';
};

subtest 'a path that changes its kind is a change' => sub {
    my $root   = tree( 'thing' => 'a file' );
    my $before = snapshot($root);
    unlink "$root/thing" or die "unlink: $!";
    mkdir "$root/thing"  or die "mkdir: $!";
    is Test::Mutation::Tree::changes( $before, snapshot($root) ), ['changed thing'], 'a file that became a directory';

    my $linked = tree( 'target' => 'x' );
    symlink 'target', "$linked/link" or die "symlink: $!";
    my $earlier = snapshot($linked);
    unlink "$linked/link" or die "unlink: $!";
    symlink 'elsewhere', "$linked/link" or die "symlink: $!";
    is Test::Mutation::Tree::changes( $earlier, snapshot($linked) ), ['changed link'], 'a link with another target';
};

# The kind of every path below a root with the content of a file and the target of a link.
sub content ( $root, @skip ) {
    my %content;
    for my $path ( sort keys snapshot( $root, @skip )->%* ) {
        my $full = "$root/$path";
        if ( -l $full ) {
            $content{$path} = 'link to ' . readlink $full;
        }
        elsif ( -d $full ) {
            $content{$path} = sprintf 'directory %04o', ( stat $full )[2] & oct '7777';
        }
        else {
            open my $handle, '<', $full or die "read $path: $!";
            $content{$path} = sprintf 'file %04o %s', ( stat $handle )[2] & oct '7777',
              do { local $/ = undef; readline $handle };
            close $handle or die "close $path: $!";
        }
    }
    return \%content;
}

sub project_tree () {
    my $root = tree(
        'lib/A.pm'             => "1;\n",
        'bin/tool'             => "#!perl\n",
        't/a.t'                => 'ok',
        't/data/deep/list.txt' => "a\nb\n",
        'docs/guide.txt'       => 'read me',
        '.git/HEAD'            => 'ref',
        '.mutation/run/x'      => 'work',
        'local/lib/perl5/B.pm' => "1;\n",
    );
    chmod oct '755', "$root/bin/tool" or die "chmod: $!";
    chmod oct '750', "$root/t/data"   or die "chmod: $!";
    mkdir "$root/empty" or die "mkdir: $!";
    symlink 'lib/A.pm', "$root/link"    or die "symlink: $!";
    symlink 'lib',      "$root/library" or die "symlink: $!";
    symlink 'docs',     "$root/mirror"  or die "symlink: $!";
    utime 1_000_000_000, 1_000_000_000, "$root/lib/A.pm" or die "utime: $!";
    return $root;
}

sub copy_of ( $root, %arg ) {
    my $to = File::Temp::tempdir( CLEANUP => 1 ) . '/deep/copy';
    Test::Mutation::Tree::copy( from => $root, to => $to, skip => [], link => [], %arg );
    return $to;
}

subtest 'copy reproduces the files, directories, and links of a tree' => sub {
    my $root = project_tree();
    my $copy = copy_of( $root, skip => [ '.git', '.mutation' ], link => [ 'local', 'absent' ] );
    is content( $copy, 'local' ), content( $root, '.git', '.mutation', 'local' ),
      'the same paths, kinds, contents, modes, and link targets, without the skipped paths';
    is content($copy)->{'bin/tool'},     "file 0755 #!perl\n", 'a command keeps its right to run';
    is content($copy)->{'t/data'},       'directory 0750',     'a directory keeps its mode';
    is readlink "$copy/local",           "$root/local",        'a linked path points at the original';
    is [ ( stat "$copy/lib/A.pm" )[9] ], [1_000_000_000],      'a file keeps its modification time';
    ok !-e "$copy/absent" && !-l "$copy/absent", 'a linked name that the tree lacks adds nothing';
    is content( copy_of($root) ), content($root), 'without a skip or a link, the copy holds everything';
    my $counted = File::Temp::tempdir( CLEANUP => 1 ) . '/copy';
    is Test::Mutation::Tree::copy( from => $root, to => $counted, skip => [ '.git', '.mutation' ], link => ['local'] ),
      scalar( keys content( $counted, 'local' )->%* ), 'the number of the copied paths, without the linked one';
};

subtest 'copy keeps a link as a link and leaves out what is no file' => sub {
    my $root = tree( 'real/file.txt' => 'x' );
    symlink 'real',            "$root/inside"  or die "symlink: $!";
    symlink '/nonexistent/at', "$root/dangles" or die "symlink: $!";
    require POSIX;
    POSIX::mkfifo( "$root/pipe", oct '600' ) or die "mkfifo: $!";
    my $copy = copy_of($root);
    is content($copy),
      {
        'real'          => content( $root, 'pipe' )->{real},
        'real/file.txt' => sprintf( 'file %04o x', ( stat "$root/real/file.txt" )[2] & oct '7777' ),
        'inside'        => 'link to real',
        'dangles'       => 'link to /nonexistent/at'
      },
      'a link to a directory stays one link, a dangling link stays, and a pipe is left out';
    my $counted = File::Temp::tempdir( CLEANUP => 1 ) . '/copy';
    my $count;
    is warns { $count = Test::Mutation::Tree::copy( from => $root, to => $counted, skip => [], link => [] ) }, 0,
      'the pipe draws no warning';
    is $count, 4, 'and is no copied path';
};

subtest 'restore undoes what was created, removed, and changed' => sub {

    # The source of the restore holds a link that leads out of it, as a copy of a project does for its modules.
    my $project  = project_tree();
    my $original = content($project);
    my $master   = copy_of( $project, skip => [ '.git', '.mutation' ], link => ['local'] );
    my $slot     = copy_of($master);
    my $before   = snapshot($slot);
    my $wanted   = content($slot);

    # A directory takes the place of that link, with a file that has the name of a file behind the link.
    unlink "$slot/local" or die "unlink: $!";
    File::Path::make_path("$slot/local/lib/perl5");
    tree_file( "$slot/local/lib/perl5/B.pm", "0;\n" );

    tree_file( "$slot/stray", 'left behind' );
    File::Path::make_path("$slot/made/deeper");
    tree_file( "$slot/made/deeper/file", 'x' );
    unlink "$slot/t/a.t" or die "unlink: $!";
    File::Path::remove_tree("$slot/t/data");
    tree_file( "$slot/lib/A.pm", "0;\n# changed\n" );
    chmod oct '555', "$slot/t"    or die "chmod: $!";
    chmod oct '711', "$slot/lib"  or die "chmod: $!";
    chmod oct '700', "$slot/docs" or die "chmod: $!";
    unlink "$slot/library" or die "unlink: $!";
    symlink 'docs', "$slot/library" or die "symlink: $!";

    # A directory takes the place of a link, with a file that has the name of a file behind the link.
    unlink "$slot/mirror" or die "unlink: $!";
    mkdir "$slot/mirror"  or die "mkdir: $!";
    tree_file( "$slot/mirror/guide.txt", 'another text' );
    unlink "$slot/bin/tool" or die "unlink: $!";
    mkdir "$slot/bin/tool"  or die "mkdir: $!";
    tree_file( "$slot/bin/tool/inner", 'x' );
    rmdir "$slot/empty" or die "rmdir: $!";
    tree_file( "$slot/empty", 'now a file' );
    unlink "$slot/link" or die "unlink: $!";
    symlink 'elsewhere', "$slot/link" or die "symlink: $!";

    my $changes = Test::Mutation::Tree::changes( $before, snapshot($slot) );
    is scalar $changes->@*, 23, 'the changes of the trial';
    is Test::Mutation::Tree::restore( from => $master, to => $slot, changes => $changes ), 23,
      'one restored path for each';
    is content($slot), $wanted, 'the tree is as it was';
    is [ grep { !/\Achanged / } Test::Mutation::Tree::changes( $before, snapshot($slot) )->@* ], [],
      'and no path is missing or left over';
    is Test::Mutation::Tree::restore( from => $master, to => $slot, changes => [] ), 0, 'no change, no work';
    is content($project), $original, 'and the tree behind the link keeps every file';
};

subtest 'remove takes a tree away, whatever rights its directories give' => sub {
    my $root = tree( 'keep/file.txt' => 'kept', 'gone/inner/file.txt' => 'x', 'gone/plain.txt' => 'y' );
    symlink '../keep', "$root/gone/link" or die "symlink: $!";
    chmod 0,         "$root/gone/inner" or die "chmod: $!";
    chmod oct '500', "$root/gone"       or die "chmod: $!";
    my $kept = content( $root, 'gone' );
    is Test::Mutation::Tree::remove("$root/gone"), 5,     'the number of removed paths';
    is content($root),                             $kept, 'the tree is gone, and the target of its link stays';
    is Test::Mutation::Tree::remove("$root/gone"), 0,     'an absent path counts nothing';

    symlink 'keep',         "$root/alias"    or die "symlink: $!";
    symlink '/nonexistent', "$root/dangling" or die "symlink: $!";
    is [ map { Test::Mutation::Tree::remove("$root/$_") } 'alias', 'dangling' ], [ 1, 1 ], 'a link counts once';
    is content($root),                                      $kept,    'and a link to a directory leaves the directory';
    is Test::Mutation::Tree::remove("$root/keep/file.txt"), 1,        'a single file';
    is [ sort keys content($root)->%* ],                    ['keep'], 'and nothing else';
};

like dies { Test::Mutation::Tree::remove() },          qr/Wrong number of parameters/, 'remove checks its arguments';
like dies { Test::Mutation::Tree::copy( from => 1 ) }, qr/Wrong number of parameters/, 'copy checks its arguments';
like dies { Test::Mutation::Tree::restore( from => 1 ) }, qr/Wrong number of parameters/,
  'restore checks its arguments';
subtest 'make creates a directory with every parent that it lacks' => sub {
    my $root = tree( 'plain.txt' => 'a file' );
    is Test::Mutation::Tree::make( "$root/a/b/c", "$root/a/d" ), 4, 'the number of new directories';
    ok -d "$root/a/b/c" && -d "$root/a/d", 'each directory stands';
    is Test::Mutation::Tree::make( "$root/a/b", $root ), 0, 'a directory that stands counts nothing';
    is Test::Mutation::Tree::make(),                     0, 'and neither does no directory at all';
    is Raised::error( sub { Test::Mutation::Tree::make("$root/plain.txt/below") } ),
      [ 'environment', 'directory-uncreatable', "cannot create $root/plain.txt: File exists" ],
      'a file in the way is named with the reason of the system';
};

subtest 'temporary creates a new directory for its caller alone' => sub {
    my $root  = tree();
    my @paths = map { Test::Mutation::Tree::temporary( $root, 'run-' ) } 1 .. 3;
    like \@paths, [ map { qr{\A\Q$root\E/run-[[:alnum:]]{6}\z} } 1 .. 3 ], 'a name with the prefix and six letters';
    is [ List::Util::uniq(@paths) ], \@paths, 'each call gives another name';
    is [ map { sprintf '%04o', ( stat $_ )[2] & oct '7777' } @paths ], [ ('0700') x 3 ],
      'the directory is open to its owner alone';
    like Raised::error( sub { Test::Mutation::Tree::temporary( "$root/absent", 'run-' ) } ),
      [
        'environment', 'directory-uncreatable',
        qr{\Acannot create \Q$root\E/absent/run-[[:alnum:]]{6}: No such file or directory\z}
      ],
      'a parent that is absent is named with the reason of the system';
};

subtest 'a failure of the system is an error of the environment with the path' => sub {
    my $root  = tree( 'from/dir/file.txt' => 'x', 'from/linked/file.txt' => 'y', 'in-the-way' => 'a file' );
    my $error = sub (%arg) {
        return Raised::error(
            sub { Test::Mutation::Tree::copy( from => "$root/from", skip => [], link => [], %arg ) } );
    };
    is $error->( from => '/nonexistent/at/all', to => "$root/x" ),
      [ 'environment', 'directory-missing', 'cannot read /nonexistent/at/all: no such directory' ],
      'copy names a tree that it cannot read';
    is $error->( to => "$root/in-the-way/copy" ),
      [ 'environment', 'directory-uncreatable', "cannot create $root/in-the-way: File exists" ],
      'copy names a target that it cannot create';

    File::Path::make_path("$root/taken/dir");
    is $error->( to => "$root/taken" ),
      [ 'environment', 'directory-uncreatable', "cannot create $root/taken/dir: File exists" ],
      'copy names a directory that stands in the target';
    File::Path::make_path("$root/held/linked");
    is $error->( to => "$root/held", link => ['linked'] ),
      [ 'environment', 'file-unlinkable', "cannot link $root/held/linked: File exists" ],
      'copy names a link that it cannot make';
};

subtest 'a copy ends at a signal that waits' => sub {
    my $root  = tree( map { ( "f$_.txt" => 'x' ) } 1 .. 5 );
    my $error = dies {
        Test::Mutation::Signals::watch(
            sub {
                kill 'TERM', $$;
                Test::Mutation::Tree::copy( from => $root, to => "$root-copy", skip => [], link => [] );
            }
        )
    };
    isa_ok $error, ['Test::Mutation::Interrupted'], 'the copy dies with the interruption';
    is [ glob "$root-copy/*" ], [], 'before it copies a file';
    Test::Mutation::Tree::remove("$root-copy");
};

subtest 'a path that the system refuses to change is named' => sub {
    Capability::has( 'unprivileged', $> != 0, 'the superuser changes every path' ) or return;
    my $root = tree( 'from/sealed.txt' => 'x', 'closed/inner/file.txt' => 'y' );
    chmod 0, "$root/from/sealed.txt" or die "chmod: $!";
    like Raised::error(
        sub { Test::Mutation::Tree::copy( from => "$root/from", to => "$root/to", skip => [], link => [] ) } ),
      [
        'environment', 'file-uncopyable',
        qr{\Acannot copy \Q$root\E/from/sealed[.]txt to \Q$root\E/to/sealed[.]txt: Permission denied\z}
      ],
      'a file without the right to read';

    chmod oct '500', "$root/closed" or die "chmod: $!";
    is Raised::error( sub { Test::Mutation::Tree::remove("$root/closed/inner") } ),
      [ 'environment', 'file-unremovable', "cannot remove $root/closed/inner: Permission denied" ],
      'a directory whose parent keeps its entries';
    chmod oct '700', "$root/closed" or die "chmod: $!";
};
like dies { Test::Mutation::Tree::snapshot( root => 1 ) }, qr/Wrong number of parameters/,
  'snapshot checks its arguments';
like dies { Test::Mutation::Tree::changes( {}, [] ) }, qr/did not pass type constraint/, 'changes checks its arguments';

done_testing;
