use v5.36;
use Test2::V0;
use Cwd         ();
use Digest::SHA ();
use File::Copy  ();
use File::Temp  ();
use lib 't/e2e/lib';
use Fixture qw(write_file);
use Test::Mutation::Store::Key;

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

sub tree ( $inside = $root ) {
    return Test::Mutation::Store::Key::tree( $inside, [], 1 );
}

subtest 'project data can describe a mutation framework' => sub {
    for my $format (qw(json html)) {
        my $path    = "$root/data/mutation.$format";
        my $content = '{"framework":{"name":"Test::Mutation"},"operand":0}';
        $content = "<html><script>$content</script></html>" if $format eq 'html';
        write_file( $path, $content );
        my $before = tree();
        write_file( $path, $content =~ s/operand":0/operand":1/r );
        isnt tree(), $before, "changed $format input changes the measurement";
    }
};

subtest 'only published bytes at their recorded paths leave the project input' => sub {
    require Test::Mutation::Report::Publication;
    my $output  = "$root/reports/parts";
    my $before  = tree();
    my %payload = (
        'mutation.json' => '{"framework":{"name":"Test::Mutation"},"score":1}',
        'mutation.html' => '<html><body>score 1</body></html>',
    );
    my %digests = map { $_ => Digest::SHA::sha256_hex( $payload{$_} ) } keys %payload;
    write_file( "$output/$_", $payload{$_} ) for keys %payload;
    Test::Mutation::Report::Publication::record( $root, $output, \%digests );
    is tree(), $before, 'nested directories with only published artifacts leave the inputs alone';
    write_file( "$output/z-data", 'first' );
    isnt tree(), $before, 'a sibling after the published artifacts remains an input';
    my $mixed = tree();
    write_file( "$output/z-data", 'other' );
    isnt tree(), $mixed, 'an edit to the ordinary sibling counts';

    for my $name ( sort keys %payload ) {
        my $with_sibling = tree();
        write_file( "$output/$name", $payload{$name} =~ tr/1/2/r );
        isnt tree(), $with_sibling, "a same-size edit to $name becomes part of the measurement";
        write_file( "$output/$name", $payload{$name} );
    }
    my $published = tree();
    chmod 0755, "$output/mutation.json" or die "make report executable: $!";
    isnt tree(), $published, 'a report repurposed as an executable affects the measurement';
    chmod 0644, "$output/mutation.json"          or die "restore report mode: $!";
    chmod 0755, "$output/.test-mutation-outputs" or die "make metadata executable: $!";
    isnt tree(), $published, 'an executable metadata file is a project input';
    chmod 0644, "$output/.test-mutation-outputs" or die "restore metadata mode: $!";
    my $original = tree();
    write_file( "$root/original.json", $payload{'mutation.json'} );
    my $regular = tree();
    unlink "$output/mutation.json" or die "replace report: $!";
    symlink "$root/original.json", "$output/mutation.json" or die "link report: $!";
    isnt tree(), $regular, 'a symlink to the expected bytes is a project input';
    unlink "$output/mutation.json" or die "remove link: $!";
    write_file( "$output/mutation.json", $payload{'mutation.json'} );
    unlink "$root/original.json" or die "remove original: $!";
    is tree(), $original, 'restoring the published file restores the measurement inputs';
    my $archive         = "$root/archive";
    my $without_archive = tree();
    write_file( "$archive/$_", $payload{$_} ) for keys %payload;
    File::Copy::copy( "$output/.test-mutation-outputs", "$archive/.test-mutation-outputs" ) or die "copy receipt: $!";
    my $copied = tree();
    isnt $copied, $without_archive, 'an exact copy of a publication is ordinary data at another path';
    write_file( "$archive/mutation.json", $payload{'mutation.json'} =~ tr/1/2/r );
    isnt tree(), $copied, 'copying a whole report directory does not exempt its contents at another path';
};

subtest 'publishing preserves a user file with the metadata name and leaves external directories alone' => sub {
    require Test::Mutation::Report::Publication;
    my $directory = "$root/conflict";
    write_file( "$directory/.test-mutation-outputs", 'project data' );
    my $payload = { 'mutation.json' => 'c' x 64 };
    my $before  = tree();
    Test::Mutation::Report::Publication::record( $root, $directory, $payload );
    is tree(), $before, 'an existing unrelated file stays unchanged';
    for my $name (qw(link directory)) {
        my $marker = "$root/$name/.test-mutation-outputs";
        write_file( "$root/$name/target", 'input' );
        if ( $name eq 'link' ) {
            symlink 'target', $marker or die "link: $!";
        }
        else {
            mkdir $marker or die "directory: $!";
        }
        my $original = tree();
        Test::Mutation::Report::Publication::record( $root, "$root/$name", $payload );
        is tree(), $original, "a $name at the metadata path survives publication";
    }
    my $outside = File::Temp::tempdir( CLEANUP => 1 );
    Test::Mutation::Report::Publication::record( $root, $outside, $payload );
    ok !-e "$outside/.test-mutation-outputs", 'publishing outside the measured tree needs no metadata';
};

subtest 'a file moved onto the metadata path during publication survives' => sub {
    my $payload = { 'mutation.json' => 'a' x 64 };
    for my $existing ( 0, 1 ) {
        my $directory = "$root/race-$existing";
        my $marker    = "$directory/.test-mutation-outputs";
        my $other     = write_file( "$directory/operand", 'a concurrent input' );
        Test::Mutation::Report::Publication::record( $root, $directory, $payload ) if $existing;
        my $hash  = \&Digest::SHA::sha256_hex;
        my $moved = 0;
        {
            no warnings 'redefine';
            local *Digest::SHA::sha256_hex = sub (@bytes) {
                if ( !$moved++ ) {
                    rename $other, $marker or die "publish concurrent input: $!";
                }
                return $hash->(@bytes);
            };
            Test::Mutation::Report::Publication::record( $root, $directory, $payload );
        }
        ok $moved, 'the input moved onto the path while recording the publication';
        is Test::Mutation::Store::Key::file($marker), Digest::SHA::sha256_hex('a concurrent input'),
          "the concurrent input wins when an earlier record exists: $existing";
    }
};

subtest 'publishing one format retains the other format and preserves hard-linked metadata' => sub {
    my $before    = tree();
    my $directory = "$root/formats";
    for my $format (qw(json html json)) {
        my $name = "mutation.$format";
        my $text = -f "$directory/$name" ? 'revised' : 'original';
        write_file( "$directory/$name", $text );
        Test::Mutation::Report::Publication::record( $root, $directory, { $name => Digest::SHA::sha256_hex($text) } );
        is tree(), $before, "publishing $text $name preserves measurements";
    }
    my $marker = "$directory/.test-mutation-outputs";
    my $data   = "$directory/input";
    link $marker, $data or die "link metadata: $!";
    my $original = Test::Mutation::Store::Key::file($data);
    Test::Mutation::Report::Publication::record( $root, $directory, { 'mutation.json' => 'b' x 64 } );
    is Test::Mutation::Store::Key::file($data), $original, 'a second hard link retains its original bytes';
    is Test::Mutation::Report::Publication::outputs( $directory, 'formats' ), {},
      'a hard-linked metadata file cannot certify output paths';
};

subtest 'a project copy keeps a relative link target and reports dangling links without warnings' => sub {
    my $project   = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $directory = "$project/history";
    my %files     = ( 'mutation.json' => 'json data', 'mutation.html' => 'html data' );
    write_file( "$directory/$_", $files{$_} ) for keys %files;
    my %keys = map { $_ => Digest::SHA::sha256_hex( $files{$_} ) } keys %files;
    Test::Mutation::Report::Publication::record( $project, $directory, \%keys );
    symlink 'history/mutation.json', "$project/input"    or die "link report: $!";
    symlink 'missing',               "$project/dangling" or die "link missing input: $!";
    my $view;
    is warnings { $view = Test::Mutation::Store::Key::project( $project, [], [] ) }, [],
      'the layout can include a dangling project link';
    my %omitted = map { $_ => 1 } $view->{outputs}->@*;
    ok !$omitted{history} && !$omitted{'history/mutation.json'}, 'the link has its original directory and file';
    ok $omitted{'history/mutation.html'}, 'a sibling publication that the link cannot reach stays hidden';
    is Test::Mutation::Store::Key::project( $project, [], ['history'] )->{outputs}, [],
      'a directory explicitly linked to the real project exposes all its contents';
};

done_testing;
