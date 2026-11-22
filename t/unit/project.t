use v5.36;
use Test2::V0;
use File::Path ();
use File::Temp ();
use Permutl::Project;

sub matches ( $pattern, $path ) {
    return $path =~ Permutl::Project::pattern_regex($pattern) ? 1 : 0;
}

subtest 'patterns' => sub {
    my @cases = (
        [ 'lib/**/*.pm', 'lib/A.pm',          1 ],
        [ 'lib/**/*.pm', 'lib/A/B/C.pm',      1 ],
        [ 'lib/**/*.pm', 'lib/A.pl',          0 ],
        [ 'lib/**/*.pm', 'xlib/A.pm',         0 ],
        [ 'lib/**/*.pm', 'lib/A.pm.bak',      0 ],
        [ 'lib/*.pm',    'lib/A.pm',          1 ],
        [ 'lib/*.pm',    'lib/A/B.pm',        0 ],
        [ 't/??.t',      't/01.t',            1 ],
        [ 't/??.t',      't/001.t',           0 ],
        [ '**/*.pm',     'A.pm',              1 ],
        [ '**/*.pm',     'deep/down/A.pm',    1 ],
        [ 'lib/A+B.pm',  'lib/A+B.pm',        1 ],
        [ 'lib/A+B.pm',  'lib/AAB.pm',        0 ],
        [ 'lib/**',      'lib/any/thing.txt', 1 ],
    );
    for my $case (@cases) {
        my ( $pattern, $path, $expected ) = $case->@*;
        is matches( $pattern, $path ), $expected, "$pattern against $path";
    }
};

subtest 'files' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    for my $path (
        'lib/A.pm',        'lib/Deep/B.pm', 'lib/Deep/notes.txt', 'lib/.hidden/C.pm',
        'local/lib/D.pm',  't/one.t',       't/sub/two.t',        't/lib/Helper.pm',
        '.git/hooks/E.pm', 'blib/lib/A.pm', 'script/tool.pl',     'lib/local/F.pm',
      )
    {
        my ($directory) = $path =~ m{\A(.*)/};
        File::Path::make_path("$root/$directory");
        open my $handle, '>', "$root/$path" or die "open $path: $!";
        close $handle or die "close $path: $!";
    }

    is Permutl::Project::files( $root, ['lib/**/*.pm'], [] ), [ 'lib/A.pm', 'lib/Deep/B.pm', 'lib/local/F.pm' ],
      'sources, without hidden directories';
    is Permutl::Project::files( $root, ['t/**/*.t'], [] ), [ 't/one.t', 't/sub/two.t' ], 'tests';
    is Permutl::Project::files( $root, ['lib/**/*.pm'], ['lib/Deep/**'] ), [ 'lib/A.pm', 'lib/local/F.pm' ],
      'an exclude pattern';
    is Permutl::Project::files( $root, [ 'lib/*.pm', 'script/*.pl', 'lib/*.pm' ], [] ),
      [ 'lib/A.pm', 'script/tool.pl' ],
      'several patterns, each file once';
    is Permutl::Project::files( $root, ['**/*.pm'], [] ),
      [ 'lib/A.pm', 'lib/Deep/B.pm', 'lib/local/F.pm', 't/lib/Helper.pm' ],
      'a pattern without a directory skips vendor directories at the root';
    is Permutl::Project::files( $root, ['missing/**/*.pm'], [] ),      [], 'a directory that does not exist';
    is warnings { Permutl::Project::files( $root, ['**/*.pm'], [] ) }, [], 'a walk from the root raises no warning';
};

subtest 'cpu_count' => sub {
    ok Permutl::Project::cpu_count() >= 1, 'at least one processor';
};

done_testing;
