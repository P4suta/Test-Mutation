use v5.36;
use Test2::V0;
use CPAN::Meta::YAML ();
use File::Temp       ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;

my $workflow = CPAN::Meta::YAML->read('.github/workflows/release-gate.yml')->[0];
my $scratch  = File::Temp::tempdir( CLEANUP => 1 );
my $mise     = write_file( "$scratch/mise", <<'SH' );
#!/bin/sh
printf '%s\n' "$@" "SHARD=${SHARD-unset}" "SHARDS=${SHARDS-unset}"
SH
chmod oct '755', $mise or die "make the command executable: $!";

sub invocation ($script) {
    local $ENV{PATH}   = "$scratch:$ENV{PATH}";
    local $ENV{SHARD}  = 2;
    local $ENV{SHARDS} = 8;
    open my $output, q{-|}, '/bin/sh', '-eu', '-c', $script or die "start the step: $!";
    chomp( my @words = readline $output );
    close $output or die "release step failed: $?";
    return \@words;
}

subtest 'the release test rejects shard numbers in the measured environment' => sub {
    my ($step) = grep { ( $_->{run} || q{} ) =~ /--shard\b/ } $workflow->{jobs}{'self-measurement'}{steps}->@*;
    my $expected = [ qw(run mutation -- --no-cache --shard 2/8 --format json), 'SHARD=unset', 'SHARDS=unset' ];
    isnt invocation('mise run mutation -- --no-cache --shard "$SHARD/$SHARDS" --format json'), $expected,
      'passing the scheduler environment would distinguish two parts';
    is invocation( $step->{run} ), $expected, 'the release passes the index only as a selection argument';
};

subtest 'the packaged command runs after disttest on both release systems' => sub {
    for my $job (qw(release macos)) {
        my @runs = map { $_->{run} } grep { exists $_->{run} } $workflow->{jobs}{$job}{steps}->@*;
        is [ @runs[ -2, -1 ] ], [ 'mise x -- make disttest', 'mise run verify-install' ],
          "$job checks an installation of the archive that passed disttest";
    }
};

Gate::checked( 'release jobs', scalar keys $workflow->{jobs}->%*, at_least => 4 );
done_testing;
