use v5.36;
use Test2::V0;
use CPAN::Meta::YAML ();
use Cwd              ();
use File::Copy       ();
use File::Path       ();
use File::Temp       ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;

my $jobs        = CPAN::Meta::YAML->read('.github/workflows/release-gate.yml')->[0]{jobs};
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

subtest 'the packaged command runs after disttest on both release systems' => sub {
    for my $job (qw(release macos)) {
        my @runs = map { $_->{run} } grep { exists $_->{run} } $jobs->{$job}{steps}->@*;
        is [ @runs[ -2, -1 ] ], [ 'mise x -- make disttest', 'mise run verify-install' ],
          "$job checks an installation of the archive that passed disttest";
    }
};

subtest 'the release runs its measured command with a stable environment' => sub {
    write_file( "$runtime/perl-path", "$interpreter\n" ) unless -f "$runtime/perl-path";
    my $script = step( $jobs->{'self-measurement'}, qr/--shard\b/ );
    for my $part ( 1, 2 ) {
        my $expected = [
            '--no-cache', '--shard', "$part/8", '--format', 'json', 42, 'LC_ALL=C',
            "PATH=$tools/$installed/perl/bin:$project/local/bin:/usr/bin:/bin",
            "PERL5LIB=$project/local/lib/perl5", 'TZ=UTC'
        ];
        is invocation( $script, $part ), $expected, "shard $part passes its index only as a command argument";
    }
};

Gate::checked( 'release jobs', scalar keys %$jobs, at_least => 4 );
done_testing;
