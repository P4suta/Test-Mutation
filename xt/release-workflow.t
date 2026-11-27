use v5.36;
use Test2::V0;
use CPAN::Meta::YAML ();
use Cwd              ();
use ExtUtils::MM     ();
use File::Copy       ();
use File::Path       ();
use File::Temp       ();
use JSON::PP         ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;

my $workflow    = CPAN::Meta::YAML->read('.github/workflows/release-gate.yml')->[0];
my $jobs        = $workflow->{jobs};
my $scratch     = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $tools       = "$scratch/tools";
my $project     = "$scratch/project";
my $runtime     = "$scratch/runner/self-runtime";
my $installed   = 'installs/perl/pinned';
my $interpreter = "$installed/perl/bin/perl";

sub executable ( $path, $text ) {
    write_file( $path, $text );
    chmod oct '755', $path or die "make the command executable: $!";
    return;
}

executable( "$scratch/bin/mise", <<'SH' );
#!/bin/sh
case "$1/$2" in
    where/perl) printf '%s\n' "$MISE_DATA_DIR/installs/perl/pinned" ;;
    which/perl) printf '%s\n' "$MISE_DATA_DIR/installs/perl/pinned/perl/bin/perl" ;;
    *) exit 1 ;;
esac
SH
File::Path::make_path("$tools/$installed/perl/bin");
File::Copy::copy( $^X, "$tools/$interpreter" ) or die "copy the test Perl: $!";
chmod oct '755', "$tools/$interpreter" or die "make the test Perl executable: $!";
write_file( "$project/local/lib/perl5/Dependency.pm", "package Dependency; sub answer { 42 } 1;\n" );
write_file( "$project/bin/mutation",                  <<'PERL' );
use Dependency;
print join("\n", @ARGV, Dependency::answer(), map { "$_=$ENV{$_}" } sort keys %ENV), "\n";
PERL

sub step ( $job, $pattern ) {
    my ($entry) = grep { ( $_->{run} || q{} ) =~ $pattern } ( $job->{steps} || [] )->@*;
    return $entry ? $entry->{run} : q{};
}

sub invocation ( $script, $shard ) {
    my $previous = Cwd::getcwd();
    chdir $project or die "enter $project: $!";
    local %ENV = (
        %ENV,
        PATH             => "$scratch/bin:$ENV{PATH}",
        MISE_DATA_DIR    => $tools,
        RUNNER_TEMP      => "$scratch/runner",
        SHARD            => $shard,
        SHARDS           => 8,
        RUNNER_NAME      => "runner-$shard",
        GITHUB_JOB       => "job-$shard",
        MISE_JOB_VALUE   => "host-$shard",
        CI_PROJECT_FLAGS => "part-$shard",
    );
    open my $output, q{-|}, '/bin/sh', '-eu', '-c', $script or die "start the step: $!";
    chomp( my @words = readline $output );
    my $closed = close $output;
    chdir $previous or die "return to $previous: $!";
    return $closed ? \@words : [];
}

subtest 'the release rejects mutable sources and controllers outside main' => sub {
    for my $input (qw(source_sha version)) {
        is $workflow->{on}{workflow_call}{inputs}{$input}{required}, 'true',   "callers must supply $input";
        is $workflow->{on}{workflow_dispatch}{inputs}{$input}{type}, 'string', "a rehearsal can choose $input";
    }
    my $script = step( $jobs->{candidate}, qr/GITHUB_REF/ );
    ok length($script), 'the workflow validates the source before checking it out' or return;
    local $ENV{GITHUB_REF} = 'refs/heads/main';
    local $ENV{SOURCE_SHA} = 'a' x 40;
    is system( 'bash', '-eu', '-c', $script ), 0, 'main can choose an immutable commit';
    {
        local $ENV{SOURCE_SHA} = 'main';
        isnt system( 'bash', '-eu', '-c', $script ), 0, 'a mutable candidate ref is refused';
    }
    local $ENV{GITHUB_REF} = 'refs/heads/other';
    isnt system( 'bash', '-eu', '-c', $script ), 0, 'a workflow dispatched outside main is refused';
};

subtest 'all release shards restore the same measured tools and dependency bytes' => sub {
    my $build   = $jobs->{'self-runtime'} || {};
    my $measure = $jobs->{'self-measurement'};
    is $measure->{needs}, 'self-runtime', 'the archive must be ready before any shard starts';
    my $pack    = step( $build,   qr/tar -czf/ );
    my $restore = step( $measure, qr/tar -xzf/ );
    ok length($pack),    'the preparation job packs the shared runtime' or return;
    ok length($restore), 'each shard restores the shared runtime'       or return;
    invocation( $pack, 1 );
    File::Path::remove_tree( $tools, "$project/local" );
    invocation( $restore, 2 );
    ok -x "$tools/$interpreter",                    'the restored target Perl is executable';
    ok -f "$project/local/lib/perl5/Dependency.pm", 'the checkout receives the prepared dependency';
};

subtest 'each measurement and build checks out the selected commit' => sub {
    for my $job (qw(candidate self-runtime self-measurement compatibility release macos)) {
        my ($checkout) = grep { ( $_->{uses} || q{} ) =~ m{\Aactions/checkout@} } ( $jobs->{$job}{steps} || [] )->@*;
        is $checkout->{with}{ref},                   q{${{ env.SOURCE_SHA }}}, "$job reads the selected commit";
        is $checkout->{with}{'persist-credentials'}, 'false', "$job leaves no credentials in the checkout";
    }
};

subtest 'candidate tools stay out of the shared Actions cache' => sub {
    my @tools = map {
        grep { ( $_->{uses} || q{} ) =~ m{\Ajdx/mise-action@} }
          $_->{steps}->@*
    } values %$jobs;
    Gate::checked( 'candidate tool installations', scalar @tools, at_least => 4 );
    is $_->{with}{cache}, 'false', 'the tool installation reads and writes no shared cache' for @tools;
};

subtest 'the candidate rejects a different version or checkout' => sub {
    my $script = step( $jobs->{candidate}, qr/git rev-parse HEAD/ );
    ok length($script), 'candidate identity comes from the checkout' or return;
    chomp( my $revision = qx{git rev-parse HEAD} );
    my $version = ExtUtils::MM->parse_version('lib/Test/Mutation.pm');
    local $ENV{GITHUB_OUTPUT} = "$scratch/identity";
    local $ENV{SOURCE_SHA}    = $revision;
    local $ENV{VERSION}       = $version;
    is system( 'bash', '-eu', '-c', $script ), 0, 'the declared version matches the selected commit';
    open my $identity, '<', $ENV{GITHUB_OUTPUT} or die "read the candidate identity: $!";
    chomp( my @values = readline $identity );
    close $identity or die "close the candidate identity: $!";
    is \@values, [ "source_sha=$revision", "version=$version" ], 'only the verified source and version are exported';
    {
        local $ENV{SOURCE_SHA} = '0' x 40;
        isnt system( 'bash', '-eu', '-c', $script ), 0, 'a different checkout is refused';
    }
    local $ENV{VERSION} = "$version.99";
    isnt system( 'bash', '-eu', '-c', $script ), 0, 'a different release version is refused';
};

subtest 'the packaged command runs after disttest on both release systems' => sub {
    for my $job (qw(release macos)) {
        my @runs = map { $_->{run} } grep { exists $_->{run} } $jobs->{$job}{steps}->@*;
        is [ @runs[ -2, -1 ] ], [ 'mise x -- make disttest', 'mise run verify-install' ],
          "$job checks an installation of the archive that passed disttest";
    }
};

subtest 'the verified output waits for both platforms and names one immutable artifact' => sub {
    my $verified = $jobs->{verified} || {};
    is $verified->{needs}, '[candidate, release, macos]', 'both tested platforms gate the artifact';
    for my $field (qw(source_sha version archive_name archive_sha256 artifact_id)) {
        is $workflow->{on}{workflow_call}{outputs}{$field}{value}, "\${{ jobs.verified.outputs.$field }}",
          "callers receive the verified $field";
    }
    my ($upload) = grep { ( $_->{uses} || q{} ) =~ m{\Aactions/upload-artifact@} } $jobs->{release}{steps}->@*;
    is $upload->{with}{name}, q{cpan-${{ env.SOURCE_SHA }}-${{ github.run_id }}-${{ github.run_attempt }}},
      'the artifact name binds the build commit, run and attempt';
    my ($install) = grep { ( $_->{run} || q{} ) eq 'mise run verify-install' } $jobs->{release}{steps}->@*;
    is $upload->{with}{path}, $install->{env}{TEST_MUTATION_DISTRIBUTION}, 'the upload uses the installed archive path';
    ok $upload->{with}{path}, 'the install and upload select one archive';
    my ($download) = grep { ( $_->{uses} || q{} ) =~ m{\Aactions/download-artifact@} } ( $verified->{steps} || [] )->@*;
    is $download->{with}{'artifact-ids'}, q{${{ needs.release.outputs.artifact_id }}},
      'verification reads the uploaded ID';
    is $download->{with}{'digest-mismatch'}, 'error', 'a transport digest mismatch fails verification';
    my ($controller) = grep { ( $_->{with}{path} || q{} ) eq 'controller' } ( $verified->{steps} || [] )->@*;
    is $controller->{with}{ref}, q{${{ github.workflow_sha }}}, 'archive verification runs the trusted controller';
};

subtest 'a retried verification rejects artifacts from other builds' => sub {
    my $script = step( $jobs->{verified}, qr/gh api/ );
    ok length($script), 'the verifier checks a GitHub artifact receipt' or return;
    executable( "$scratch/bin/gh", "#!/bin/sh\nprintf '%s\\n' \"\$RECEIPT\"\n" );
    local $ENV{PATH}               = "$scratch/bin:$ENV{PATH}";
    local $ENV{SOURCE_SHA}         = 'ab' x 20;
    local $ENV{ARTIFACT_ID}        = 55;
    local $ENV{GITHUB_REPOSITORY}  = 'fixture/distribution';
    local $ENV{GITHUB_RUN_ID}      = 11;
    local $ENV{GITHUB_RUN_ATTEMPT} = 2;
    local $ENV{BUILD_ATTEMPT}      = 1;
    my %receipt = (
        name         => "cpan-$ENV{SOURCE_SHA}-11-1",
        id           => 55,
        workflow_run => { id => 11 },
        expired      => JSON::PP::false,
    );
    local $ENV{RECEIPT} = JSON::PP->new->encode( \%receipt );
    is system( 'bash', '-euo', 'pipefail', '-c', $script ), 0,
      'retrying macOS can reuse the exact successful Linux artifact';

    for my $mismatch ( [ id => 56 ], [ workflow_run => { id => 12 } ], [ expired => JSON::PP::true ],
        [ name => 'other' ] )
    {
        local $ENV{RECEIPT} = JSON::PP->new->encode( { %receipt, @$mismatch } );
        isnt system( 'bash', '-euo', 'pipefail', '-c', $script ), 0, 'a conflicting receipt is rejected';
    }
};

subtest 'the release test rejects shard numbers in the measured environment' => sub {
    write_file( "$runtime/perl-path", "$interpreter\n" ) unless -f "$runtime/perl-path";
    my $script = step( $jobs->{'self-measurement'}, qr/--shard\b/ );
    for my $part ( 1, 2 ) {
        my $expected = [
            '--no-cache', '--shard', "$part/8", '--format', 'json', 42, 'LC_ALL=C',
            "PATH=$tools/$installed/perl/bin:$project/local/bin:/usr/bin:/bin",
            "PERL5LIB=$project/local/lib/perl5", 'TZ=UTC'
        ];
        my $leaking = $script =~ s/LC_ALL=C/SHARD=$part LC_ALL=C/r;
        isnt invocation( $leaking, $part ), $expected, 'inheriting the scheduler index changes the measured inputs';
        is invocation( $script, $part ),    $expected, "shard $part passes its index only as a command argument";
    }
};

Gate::checked( 'release jobs', scalar keys %$jobs, at_least => 4 );
done_testing;
