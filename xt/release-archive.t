use v5.36;
use Test2::V0;
use Archive::Tar ();
use Digest::SHA  ();
use File::Temp   ();
use JSON::PP     ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;

my $scratch = File::Temp::tempdir( CLEANUP => 1 );
my $source  = "$scratch/project";
my $version = '2.003';
my $name    = "Test-Mutation-$version";
my $path    = "$scratch/$name.tar.gz";
my %files   = (
    'lib/Test/Mutation.pm' => "package Test::Mutation;\nour \$VERSION = '$version';\n1;\n",
    'bin/mutation'         => "print qq{verified command\\n};\n"
);
write_file( "$source/$_", $files{$_} ) for keys %files;
my @git = (
    'git',                      '-C', $source,                '-c',
    'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c',
    'user.name=Release test',   '-c', 'user.email=release@example.invalid'
);
system( @git, 'init', '-q' ) == 0 or die 'create a candidate repository';
system( @git, 'add',  '.' ) == 0  or die 'stage the candidate files';
system( @git, 'commit', '-qm', 'Prepare the distribution' ) == 0 or die 'commit the candidate';
open my $head, q{-|}, @git, 'rev-parse', 'HEAD' or die "read the candidate commit: $!";
chomp( my $commit = readline $head );
close $head or die 'resolve the candidate commit';
$files{'META.json'} = JSON::PP->new->encode( { name => 'Test-Mutation', version => $version } );
$files{'META.yml'}  = "---\nname: Test-Mutation\nversion: '$version'\n";
$files{MANIFEST}    = join q{}, map { "$_\n" } sort( keys %files, 'MANIFEST' );

sub archive ($members) {
    my $tar = Archive::Tar->new;
    $tar->add_data( "$name/$_", $members->{$_} ) for sort keys %$members;
    $tar->write( $path, Archive::Tar::COMPRESS_GZIP() ) or die 'write the candidate archive';
    open my $file, '<:raw', $path or die "read the candidate archive: $!";
    my $digest = Digest::SHA->new(256)->addfile($file)->hexdigest;
    close $file or die "close the candidate archive: $!";
    return $digest;
}

sub verify ( $file, $revision, $expected_version, $digest ) {
    my $pid = open my $result, q{-|};
    die "start the verifier: $!" unless defined $pid;
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or die "capture the archive diagnostic: $!";
        exec {$^X} $^X, 'xt/bin/verify-release-archive', $source, $revision, $expected_version, $file, $digest
          or die "run the archive verifier: $!";
    }
    my $text = do { local $/ = undef; readline $result };
    close $result;
    return [ $? >> 8, $text // q{} ];
}

my $digest = archive( \%files );
is verify( $path, $commit, $version, $digest ), [ 0, "archive_name=$name.tar.gz\narchive_sha256=$digest\n" ],
  'the verifier identifies the tested archive and its digest';

subtest 'verification rejects an incorrect archive identity' => sub {
    for my $case (
        [ $path, $commit,  $version, 'a' x 64, qr/SHA-256/ ],
        [ $path, '0' x 40, $version, $digest,  qr/commit/ ],
        [ $path, $commit,  '2.004',  $digest,  qr/name/ ],
      )
    {
        my ( $file, $revision, $release, $expected, $reason ) = @$case;
        my $outcome = verify( $file, $revision, $release, $expected );
        isnt $outcome->[0], 0, 'a mismatch stops the verification';
        like $outcome->[1], $reason, 'the diagnostic identifies the mismatch';
    }
};

subtest 'verification rejects altered source and metadata in a correctly named archive' => sub {
    for my $case (
        [ 'bin/mutation',         '# another revision',                           qr/bin\/mutation/ ],
        [ 'lib/Test/Mutation.pm', undef,                                          qr/lib\/Test\/Mutation[.]pm/ ],
        [ 'lib/Extra.pm',         '1;',                                           qr/lib\/Extra[.]pm/ ],
        [ 'META.json',            '{"name":"Other","version":"2.003"}',           qr/META[.]json/ ],
        [ 'META.yml',             "---\nname: Test-Mutation\nversion: '2.002'\n", qr/META[.]yml/ ],
      )
    {
        my ( $member, $replacement, $reason ) = @$case;
        my %changed = %files;
        if ( defined $replacement ) { $changed{$member} = $replacement }
        else                        { delete $changed{$member} }
        my $outcome = verify( $path, $commit, $version, archive( \%changed ) );
        isnt $outcome->[0], 0, 'even a matching digest cannot accept different files';
        like $outcome->[1], $reason, 'the diagnostic names the affected member';
    }
};

Gate::checked( 'files in the candidate archive', scalar keys %files, at_least => 5 );
done_testing;
