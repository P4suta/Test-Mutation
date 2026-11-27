use v5.36;
use Test2::V0;
use Digest::SHA qw(sha256_hex);
use File::Copy  qw(copy);
use File::Temp  ();
use FindBin     ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(write_file);
use Gate;

my $root   = File::Temp::tempdir( CLEANUP => 1 );
my $tool   = "$root/draft";
my $source = 'ab' x 20;
my $name   = 'Test-Mutation-0.001.tar.gz';
my $bytes  = 'the tested distribution';
my $digest = sha256_hex($bytes);
my %commands;
my $compiled = system( 'rustc', '--edition=2021', '-D', 'warnings', "$FindBin::Bin/draft.rs", '-o', $tool );
is $compiled, 0, 'the draft controller compiles' or bail_out('the draft controller is unavailable');
copy( "$FindBin::Bin/fake-gh", "$root/gh" ) or die "copy fake gh: $!";
chmod oct '755', "$root/gh" or die "mark fake gh executable: $!";

sub read_file ($path) {
    open my $in, '<:raw', $path or die "read $path: $!";
    local $/ = undef;
    return readline $in;
}

sub setup () {
    my $area = File::Temp::tempdir( DIR => $root );
    mkdir "$area/staging" or die "create staging: $!";
    write_file( "$area/candidate/$name", $bytes );
    write_file( "$area/remote/draft",    'true' );
    write_file( "$area/remote/tag",      $source );
    return (
        %ENV,
        PATH                => "$area:$root:$ENV{PATH}",
        GITHUB_REPOSITORY   => 'P4suta/Test-Mutation',
        CPAN_SOURCE_SHA     => $source,
        CPAN_TAG            => 'v0.1.0',
        CPAN_VERSION        => '0.001',
        CPAN_RELEASE_ID     => '17',
        CPAN_ARCHIVE_SHA256 => $digest,
        CPAN_CANDIDATE_DIR  => "$area/candidate",
        CPAN_STAGING_DIR    => "$area/staging",
        FAKE_REMOTE         => "$area/remote",
        TEST_AREA           => $area,
    );
}

sub invoke ($action) {
    ++$commands{$action};
    open my $output, q{-|}, $tool, $action or die "run $action: $!";
    local $/ = undef;
    my $text = readline $output;
    my $ok   = close $output;
    return $ok ? ( $text // q{} ) : undef;
}

subtest 'staging rejects invalid source, version and archive identities' => sub {
    for my $case (
        [ CPAN_SOURCE_SHA     => 'cd' x 20 ],
        [ CPAN_TAG            => 'v0.0.1' ],
        [ CPAN_ARCHIVE_SHA256 => 'af' x 32 ],
        [ CPAN_RELEASE_ID     => 'different' ],
      )
    {
        local %ENV = setup();
        local $ENV{ $case->[0] } = $case->[1];
        is invoke('stage'), undef, "reject an invalid $case->[0]";
        ok !-e $ENV{FAKE_REMOTE} . "/$name", 'a rejected candidate leaves the draft empty';
    }
};

subtest 'only the release tag can identify the source' => sub {
    local %ENV = setup();
    unlink $ENV{FAKE_REMOTE} . "/tag" or die "remove the tag: $!";
    is invoke('stage'), undef, 'a branch with the same name cannot authorize publication';
    write_file( $ENV{FAKE_REMOTE} . "/tag", 'cd' x 20 );
    is invoke('stage'), undef, 'a tag pointing to another commit cannot authorize publication';
    ok !-e $ENV{FAKE_REMOTE} . "/$name", 'the rejected reference leaves the draft empty';
};

subtest 'publication rejects versions that Perl cannot distinguish' => sub {
    local %ENV               = setup();
    local $ENV{CPAN_TAG}     = 'v2147483648.1.0';
    local $ENV{CPAN_VERSION} = '2147483648.001';
    write_file( $ENV{CPAN_CANDIDATE_DIR} . '/Test-Mutation-2147483648.001.tar.gz', $bytes );
    is invoke('stage'), undef, 'the overflowing version cannot select a release';
    ok !-e $ENV{FAKE_REMOTE} . '/api-used', 'the controller rejects the version before calling GitHub';
};

subtest 'only the first reservation may submit the archive' => sub {
    local %ENV = setup();
    like invoke('stage'), qr/^action=prepare$/m, 'the verified archive is ready for a reservation';
    is read_file( $ENV{FAKE_REMOTE} . "/$name" ), $bytes, 'the draft receives the tested file';
    like invoke('claim'), qr/^action=submit$/m,    'creating the checksum reserves one upload';
    like invoke('claim'), qr/^action=reconcile$/m, 'a second claim checks the registry';
    like invoke('stage'), qr/^action=reconcile$/m, 'a restarted run also checks the registry';
    is read_file( $ENV{FAKE_REMOTE} . "/$name.sha256" ), "$digest  $name\n", 'the receipt names the archive digest';
};

subtest 'staging recovers an interrupted archive upload' => sub {
    local %ENV = setup();
    my $remote = $ENV{FAKE_REMOTE};
    write_file( "$remote/$name.interrupt", 1 );
    is invoke('stage'),                  undef,     'the server lost the upload';
    is read_file("$remote/$name.state"), 'starter', 'GitHub kept the empty asset';
    like invoke('stage'), qr/^action=prepare$/m, 'a retry stages the verified archive';
    is read_file("$remote/$name"),         $bytes, 'the retry retained the tested bytes';
    is read_file("$remote/$name.deleted"), 10,     'only the incomplete archive was removed';
};

subtest 'staging recovers an interrupted reservation before one submission' => sub {
    local %ENV = setup();
    my $remote = $ENV{FAKE_REMOTE};
    invoke('stage');
    write_file( "$remote/$name.sha256.interrupt", 1 );
    is invoke('claim'), undef, 'the checksum upload failed';
    like invoke('stage'), qr/^action=prepare$/m,   'a retry can reserve the candidate';
    like invoke('claim'), qr/^action=submit$/m,    'the completed reservation permits one submission';
    like invoke('claim'), qr/^action=reconcile$/m, 'the next claim only checks the registry';
    ok !-e "$remote/$name.deleted", 'the original archive was preserved';
    is read_file("$remote/$name.sha256.deleted"), 11, 'only the incomplete receipt was removed';
};

subtest 'a completed upload wins over an earlier incomplete observation' => sub {
    for my $receipt ( 0, 1 ) {
        local %ENV = setup();
        my $remote = $ENV{FAKE_REMOTE};
        my $file   = $receipt ? "$name.sha256" : $name;
        invoke('stage') if $receipt;
        write_file( "$remote/$file.interrupt", 1 );
        is invoke( $receipt ? 'claim' : 'stage' ), undef, 'the previous request was interrupted';
        write_file( "$remote/$file.complete", $receipt ? "$digest  $name\n" : $bytes );
        my $expected = $receipt ? 'reconcile' : 'prepare';
        like invoke('stage'), qr/^action=\Q$expected\E$/m, 'the completed asset determines the next action';
        ok !-e "$remote/$file.deleted", 'the completed upload keeps its asset ID and bytes';
    }
};

subtest 'a published draft cannot lose an incomplete asset' => sub {
    local %ENV = setup();
    my $remote = $ENV{FAKE_REMOTE};
    write_file( "$remote/$name.interrupt", 1 );
    is invoke('stage'), undef, 'the archive upload was interrupted';
    write_file( "$remote/publish-after-list", 1 );
    is invoke('stage'), undef, 'publication stops cleanup of an earlier draft observation';
    ok -e "$remote/$name",          'the public asset remains in place';
    ok !-e "$remote/$name.deleted", 'the workflow sent no delete request';
};

subtest 'recovery keeps the original verified bytes' => sub {
    local %ENV = setup();
    invoke('stage');
    invoke('claim');
    write_file( $ENV{CPAN_CANDIDATE_DIR} . "/$name", 'different bytes from the same source' );
    local $ENV{CPAN_ARCHIVE_SHA256} = sha256_hex('different bytes from the same source');
    my $recovered = invoke('stage');
    like $recovered, qr/^action=reconcile$/m,   'an existing submission only needs reconciliation';
    like $recovered, qr/^sha256=\Q$digest\E$/m, 'the original digest identifies the release';
    is read_file( $ENV{CPAN_STAGING_DIR} . "/$name" ), $bytes, 'the public copy must match the original Linux artifact';
};

subtest 'an unreserved archive must match the current release gate' => sub {
    local %ENV = setup();
    invoke('stage');
    write_file( $ENV{FAKE_REMOTE} . "/$name", 'an unverified archive' );
    is invoke('stage'), undef, 'the workflow refuses to prepare different bytes without a reservation';
    write_file( $ENV{CPAN_STAGING_DIR} . "/$name", 'an unverified archive' );
    is invoke('claim'), undef, 'a direct claim also verifies the original candidate checksum';
    ok !-e $ENV{FAKE_REMOTE} . "/$name.sha256", 'the conflicting archive cannot acquire a receipt';
};

subtest 'foreign assets and conflicting receipts stop recovery' => sub {
    local %ENV = setup();
    invoke('stage');
    write_file( $ENV{FAKE_REMOTE} . "/$name.author", 'other-user' );
    is invoke('stage'), undef, 'a foreign upload cannot establish candidate provenance';
    write_file( $ENV{FAKE_REMOTE} . "/$name.author", 'github-actions[bot]' );
    invoke('claim');
    write_file( $ENV{FAKE_REMOTE} . "/$name.sha256", 'another checksum' );
    is invoke('claim'), undef, 'a conflicting receipt cannot authorize a submission';
};

subtest 'final publication needs a matching registry archive' => sub {
    local %ENV = setup();
    invoke('stage');
    is invoke('finish'), undef, 'the draft cannot be published before the upload is reserved';
    invoke('claim');
    my $pause = $ENV{TEST_AREA} . "/pause";
    write_file( $pause, "#!/bin/sh\nexit 3\n" );
    chmod oct '755', $pause or die "mark pause executable: $!";
    is invoke('finish'),                          undef,  'a missing registry archive keeps the draft private';
    is read_file( $ENV{FAKE_REMOTE} . "/draft" ), 'true', 'the draft is still private';
    write_file( $pause, qq{#!/bin/sh\ntest "\$1" = reconcile && test -f "\$2" && test "\$3" = $digest\n} );
    ok defined( invoke('finish') ), 'the verified upload can complete publication';
    ok defined( invoke('finish') ), 'publishing the same release again succeeds';
    is read_file( $ENV{FAKE_REMOTE} . "/edits" ), 1, 'the draft becomes public once';
};

Gate::checked( 'publication commands', scalar keys %commands, at_least => 3 );
done_testing;
