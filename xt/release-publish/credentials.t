use v5.36;
use Test2::V0;
use CPAN::Meta::YAML ();
use File::Temp       ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;

my $workflow = CPAN::Meta::YAML->read('.github/workflows/release-credentials.yml')->[0];
my $jobs     = $workflow->{jobs};

subtest 'only a protected main dispatch can read the independent credentials' => sub {
    is [ sort keys %{ $workflow->{on} } ], ['workflow_dispatch'],     'only a manual dispatch';
    is [ sort keys %$jobs ],               [qw(cpan release-please)], 'one job per credential';
    for my $name ( sort keys %$jobs ) {
        my $job = $jobs->{$name};
        is $job->{environment}, $name, 'the credential belongs to its environment';
        ok !exists $job->{needs}, 'a missing credential leaves the other check available';
        like $job->{if}, qr/github[.]ref == 'refs\/heads\/main'/, 'only main';
        like $job->{if}, qr/github[.]ref_protected/,              'the ref must have protection';
        my ($fetch) = grep { ( $_->{uses} || q{} ) =~ m{\ADopplerHQ/secrets-fetch-action\@}i } @{ $job->{steps} };
        is $fetch->{with}{'doppler-token'},   q{${{ secrets.DOPPLER_TOKEN }}}, 'only the config service token';
        is $fetch->{with}{'inject-env-vars'}, 'false', 'secrets are limited to their consuming step';
    }
};

subtest 'the publishing credential is limited to the read-only adapter' => sub {
    my @steps = $jobs->{cpan}{steps}->@*;
    my ($compile) = grep { ( $_->{run} || q{} ) =~ /rustc/ } @steps;
    like $compile->{run}, qr{xt/release-publish/pause[.]rs}, 'compile the trusted adapter';
    ok !exists $compile->{env}, 'the compiler does not receive a publishing credential';
    my $check = $steps[-1];
    is $check->{env}{PAUSE_TOKEN}, q{${{ steps.doppler.outputs.PAUSE_TOKEN }}}, 'the last step receives the token';
    like $check->{run}, qr{\A"?\$RUNNER_TEMP/pause"? preflight\s*\z}, 'the credential command has no archive operand';
};

subtest 'the installation check rejects another repository or a broader token' => sub {
    my @steps = $jobs->{'release-please'}{steps}->@*;
    my ($app) = grep { ( $_->{uses} || q{} ) =~ m{\Aactions/create-github-app-token\@} } @steps;
    is $app->{with}{'permission-contents'}, 'read',                                         'read access is sufficient';
    is $app->{with}{'client-id'},   q{${{ steps.doppler.outputs.GITHUB_APP_CLIENT_ID }}},   'the proposal app identity';
    is $app->{with}{'private-key'}, q{${{ steps.doppler.outputs.GITHUB_APP_PRIVATE_KEY }}}, 'the proposal app key';

    my $scratch = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$scratch/gh", <<'SH' );
#!/bin/sh
test "$*" = 'api /installation/repositories' || exit 7
printf '%s\n' "$INSTALLATION"
SH
    chmod oct '755', "$scratch/gh" or die "make the test command executable: $!";
    local $ENV{PATH}              = "$scratch:$ENV{PATH}";
    local $ENV{GITHUB_REPOSITORY} = 'P4suta/Test-Mutation';
    my $script = $steps[-1]{run};
    for my $case (
        [ '{"total_count":1,"repositories":[{"full_name":"P4suta/Test-Mutation"}]}', 0 ],
        [ '{"total_count":1,"repositories":[{"full_name":"P4suta/Other"}]}',         1 ],
        [ '{"total_count":2,"repositories":[{"full_name":"P4suta/Test-Mutation"}]}', 1 ],
        [ '{"total_count":0,"repositories":[]}',                                     1 ],
      )
    {
        local $ENV{INSTALLATION} = $case->[0];
        is 0 + ( system( '/bin/bash', '-eu', '-o', 'pipefail', '-c', $script ) != 0 ), $case->[1],
          'the token lists exactly the destination repository';
    }
};

Gate::checked( 'credential jobs', scalar keys %$jobs, at_least => 2 );
done_testing;
