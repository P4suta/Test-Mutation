use v5.36;
use Test2::V0;
use File::Temp ();
use JSON::PP   ();
use lib 't/e2e/lib';
use Fixture qw(write_file);

my $dir    = File::Temp::tempdir( CLEANUP => 1 );
my $repo   = 'P4suta/Test-Mutation';
my $owner  = 42543015;
my $source = 'ab' x 20;
my $head   = 'cd' x 20;
my $tree   = 'ef' x 20;
my $pass   = { context => 'release/local', state => 'success', creator => { id => $owner } };
my $json   = JSON::PP->new;

write_file( "$dir/gh", <<'PERL' );
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP ();
my $path = pop @ARGV;
my $pages = $path =~ m{/statuses[?]per_page=100\z} ? 1 : 0;
die "unexpected gh arguments: @ARGV" unless "@ARGV" eq ( $pages ? 'api --paginate --slurp' : 'api' );
my $responses = JSON::PP::decode_json( $ENV{CHECK_RESPONSES} );
die "unexpected API request: $path" unless exists $responses->{$path};
print JSON::PP::encode_json( $responses->{$path} );
exit( $path eq ( $ENV{FAILED_REQUEST} || q{} ) ? 1 : 0 );
PERL
chmod oct('755'), "$dir/gh" or die "chmod gh: $!";

sub statuses ($sha) { return "repos/$repo/commits/$sha/statuses?per_page=100" }
sub commit   ($sha) { return "repos/$repo/git/commits/$sha" }

sub admits ( $responses, $event = {}, %env ) {
    write_file( "$dir/event.json", $json->encode($event) );
    local %ENV = (
        %ENV,
        PATH                => "$dir:$ENV{PATH}",
        SOURCE_SHA          => $source,
        GITHUB_SHA          => $source,
        GITHUB_REPOSITORY   => $repo,
        GITHUB_EVENT_NAME   => 'workflow_dispatch',
        GITHUB_EVENT_PATH   => "$dir/event.json",
        REPOSITORY_OWNER_ID => $owner,
        CHECK_RESPONSES     => $json->encode($responses),
        %env
    );
    return system( 'bash', 'xt/bin/verify-local-release-check' ) == 0;
}

subtest 'the candidate requires its latest local status from the repository account' => sub {
    my $endpoint = statuses($source);
    my $other    = { %$pass, context => 'other', state => 'failure' };
    ok admits( { $endpoint => [ [$other], [$pass] ] } ), 'a successful status on a later page approves the candidate';
    for my $update (
        { %$pass, state   => 'failure' },
        { %$pass, state   => 'pending' },
        { %$pass, creator => { id => $owner + 1 } }
      )
    {
        ok !admits( { $endpoint => [ [ $update, $pass ] ] } ), 'an older success cannot replace the latest status';
    }
    ok !admits( { $endpoint => [ [$other] ] } ), 'a manual rehearsal requires the selected commit to pass';
    ok !admits( { $endpoint => [ [$pass] ] }, {}, FAILED_REQUEST => $endpoint ),
      'an API failure invalidates even a partial success response';
};

done_testing;
