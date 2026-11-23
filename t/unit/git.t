use v5.36;
use Test2::V0;
use Cwd        ();
use File::Path ();
use File::Temp ();
use Permutl::Diff;
use Permutl::Git;

skip_all 'the test needs the git command' if !length qx{git --version 2>/dev/null};

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

sub git (@arguments) {
    my @command = (
        'git', '-C', $root, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Test',
        '-c',  'user.email=test@example.invalid',
        '-c',  'commit.gpgsign=false', @arguments,
    );
    system(@command) == 0 or die "git @arguments failed";
    return;
}

sub write_lines ( $path, @lines ) {
    my ($directory) = "$root/$path" =~ m{\A(.*)/};
    File::Path::make_path($directory);
    open my $handle, '>', "$root/$path" or die "write $path: $!";
    print {$handle} map { "$_\n" } @lines or die "write $path: $!";
    close $handle                         or die "close $path: $!";
    return;
}

my @lines = map { "line $_" } 1 .. 80;
write_lines( 'lib/Kept.pm', @lines );
git( 'init',   '-q' );
git( 'add',    q{.} );
git( 'commit', '-q', '-m', 'initial' );

is Permutl::Git::changed( $root, 'HEAD' ), {}, 'an unchanged tree has no changed line';

$lines[2]  = 'another third line';
$lines[69] = 'another line seventy';
write_lines( 'lib/Kept.pm',  @lines );
write_lines( 'lib/Added.pm', map { "new $_" } 1 .. 100 );
my $changed = Permutl::Git::changed( $root, 'HEAD' );
is $changed->{'lib/Kept.pm'}, [ [ 3, 3 ], [ 70, 70 ] ], 'the changed lines of a tracked file';
is [ sort keys $changed->%* ], [ 'lib/Added.pm', 'lib/Kept.pm' ], 'a file that git does not track is changed too';
ok Permutl::Diff::touches( $changed->{'lib/Added.pm'}, 100_000, 100_000 ), 'and every line of it counts as changed';

like dies { Permutl::Git::changed( $root, 'no-such-revision' ) },
  qr/\Agit diff failed: [^\n]*no-such-revision[^\n]*\n\z/, 'an unknown revision gives one line with the reason of git';

my $plain = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
like dies { Permutl::Git::changed( $plain, 'HEAD' ) }, qr/\Agit diff failed: [^\n]+\n\z/,
  'a directory outside a repository gives the reason of git';

{
    local $ENV{PATH} = $plain;
    like dies { Permutl::Git::changed( $root, 'HEAD' ) }, qr/\Agit diff failed: cannot start git: [^\n]+\n\z/,
      'a machine without git gets a message that names the command';
}

done_testing;
