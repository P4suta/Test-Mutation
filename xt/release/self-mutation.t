use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/lib';
use Gate;
use Library;
use SelfMeasurement;
use Test::Mutation::Result;
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $config = Test::Mutation::Settings::of_call( { root => q{.} } );
ok $config->suppress_require_names && $config->suppress_require_reason,
  'each suppression names its mutators and reason';
my $selection = Test::Mutation::Select::resolve( config => $config );
my $result    = SelfMeasurement::read_report('mutation-report/mutation.json');
my @sources = sort( Library::modules()->@*, 'bin/mutation', 'xt/lib/SelfMeasurement.pm', 'xt/lib/LibraryCoverage.pm' );
is [ sort keys $selection->sources->%* ], \@sources,
  'the project measures every module, the command and its release policy';

subtest 'the release rejects an interrupted measurement' => sub {
    my $incomplete = Test::Mutation::Result->new( $result->%*, interrupted => 'TERM' );
    like SelfMeasurement::findings( $incomplete, $selection ), bag { item qr/TERM/; etc },
      'an interrupt invalidates even a report that already contains every mutant';
};

is SelfMeasurement::findings( $result, $selection ), [], 'a complete self measurement scores 100 percent';
my @shim = grep { $_->{mutant}->path eq 'lib/Test/Mutation/Shim.pm' && $_->{status} eq 'Killed' } $result->entries->@*;
Gate::checked( 'detected shim mutants',    scalar @shim,                at_least => 1 );
Gate::checked( 'measured mutants',         scalar $result->entries->@*, at_least => 1 );
Gate::checked( 'analyzed project sources', scalar @sources,             at_least => 1 );
done_testing;
