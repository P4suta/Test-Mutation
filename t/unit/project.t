use v5.36;
use Test2::V0;
use File::Path ();
use File::Temp ();
use lib 't/lib';
use Capability;
use Test::Mutation::Project;

sub matches ( $pattern, $path ) {
    return $path =~ Test::Mutation::Project::pattern_regex($pattern) ? 1 : 0;
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

    is Test::Mutation::Project::files( $root, ['lib/**/*.pm'], [] ), [ 'lib/A.pm', 'lib/Deep/B.pm', 'lib/local/F.pm' ],
      'sources, without hidden directories';
    is Test::Mutation::Project::files( $root, ['t/**/*.t'], [] ), [ 't/one.t', 't/sub/two.t' ], 'tests';
    is Test::Mutation::Project::files( $root, ['lib/**/*.pm'], ['lib/Deep/**'] ), [ 'lib/A.pm', 'lib/local/F.pm' ],
      'an exclude pattern';
    is Test::Mutation::Project::files( $root, [ 'lib/*.pm', 'script/*.pl', 'lib/*.pm' ], [] ),
      [ 'lib/A.pm', 'script/tool.pl' ],
      'several patterns, each file once';
    is Test::Mutation::Project::files( $root, ['**/*.pm'], [] ),
      [ 'lib/A.pm', 'lib/Deep/B.pm', 'lib/local/F.pm', 't/lib/Helper.pm' ],
      'a pattern without a directory skips vendor directories at the root';
    is Test::Mutation::Project::files( $root, ['missing/**/*.pm'], [] ), [], 'a directory that does not exist';
    is warnings { Test::Mutation::Project::files( $root, ['**/*.pm'], [] ) }, [],
      'a walk from the root raises no warning';
    is Test::Mutation::Project::files( $root, [ 'missing/**/*.pm', 'lib/*.pm' ], [] ), ['lib/A.pm'],
      'a directory that does not exist before a pattern that matches';

    if ( Capability::has( 'unprivileged', $> != 0, 'the superuser reads every directory' ) ) {
        mkdir "$root/forbidden" or die "mkdir: $!";
        chmod 0, "$root/forbidden" or die "chmod: $!";
        my @warnings = warnings { Test::Mutation::Project::files( $root, ['lib/**/*.pm'], [] ) }->@*;
        my @walked   = warnings { Test::Mutation::Project::files( $root, ['**/*.pm'],     [] ) }->@*;
        chmod 0700, "$root/forbidden" or die "chmod: $!";
        is \@warnings, [], 'a pattern under one directory reads no other directory';
        ok scalar(@walked), 'and a walk from the root does try the unreadable directory';
    }
};

subtest 'the default script set follows the selected interpreter' => sub {
    my $root    = File::Temp::tempdir( CLEANUP => 1 );
    my @scripts = (
        [ 'direct',          "#!/usr/local/bin/perl5.38 -w\nexit;\n",                         1 ],
        [ 'portable',        "#!/usr/bin/env -S perl -w\nexit;\n",                            1 ],
        [ 'plain.pl',        "print 7;\n",                                                    1 ],
        [ 'utf8.pl',         "\xEF\xBB\xBF#!/usr/bin/perl\nprint 7;\n",                       1 ],
        [ 'marked-command',  "\xEF\xBB\xBF#!perl -w\nprint 7;\n",                             1 ],
        [ 'marked-shell.pl', "\xEF\xBB\xBF#!/bin/sh\nexit 0\n",                               0 ],
        [ 'binary.pl',       "\x00" . ( 'x' x 8192 ),                                         0 ],
        [ 'shell.pl',        "#!/bin/sh\n# a perl program follows some other time\nexit 0\n", 0 ],
        [ 'preamble.pl',     "#!/bin/sh\nexec perl -x \"\$0\"\n#!perl\nprint 7;\n",           1 ],
        [ 'readme',          "useful example:\n#!perl\nprint 7;\n",                           0 ],
        [ 'ambiguous',       "#!/opt/perl-helper/bin/sh\n",                                   0 ],
    );
    for my $script (@scripts) {
        my ( $file, $bytes, $expected ) = @$script;
        open my $out, '>:raw', "$root/$file" or die "open $file: $!";
        print {$out} $bytes;
        close $out or die "close $file: $!";
        is Test::Mutation::Project::perl_script("$root/$file"), $expected, $file;
    }
    like dies { Test::Mutation::Project::perl_script( [] ) }, qr/type constraint "Str"/,
      'script detection checks the supplied path';
    is Test::Mutation::Project::perl_script($root), 0, 'directories cannot be commands';
};

subtest 'default_jobs leaves one processor free' => sub {
    is [ map { Test::Mutation::Project::default_jobs($_) } 1, 2, 3, 8 ], [ 1, 1, 2, 7 ],
      'one less, and never below one';
};

done_testing;
