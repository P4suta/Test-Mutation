use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/discovery/lib';
use Gate;
use Discovery::Check;
use Discovery::Engine;
use Discovery::Probe;
use Discovery::Tier;

# The unmodified run of the tool starts each test as prove starts it.
# Every test writes its taint mode, its module search path, and its environment under both, for each spelling of a first line.

Discovery::Tier::announce();

subtest 'the comparison rejects a state that differs from the one of prove' => sub {
    my %state = ( verdict => 'pass', taint => 1, inc => [ '<root>/lib', '/perl/lib' ], env => { HARNESS_ACTIVE => 1 } );
    my $found = sub ( $changed, $other = {} ) {
        my %prove = ( 't/T.t' => {%state}, 't/plain.t' => { %state, taint => 0 } );
        my %tool  = ( 't/T.t' => { %state, $changed->%* }, 't/plain.t' => { %state, taint => 0, $other->%* } );
        return [ Discovery::Check::findings( ['baseline'], prove => \%prove, tool => \%tool ) ];
    };
    is $found->( {} ), [], 'the same state under both';
    is $found->( { taint => 0 } ), ['first-line=T: the taint mode differs from the one of prove'], 'another taint mode';
    is $found->( { verdict => 'fail' } ),
      ['first-line=T: the verdict of prove differs from the unmodified run of the tool'], 'another verdict';
    is $found->( { inc => ['/perl/lib'] } ), ['first-line=T: the search path of modules lacks an entry of prove'],
      'a lost entry of the search path';
    is $found->( { inc => [ '<root>/lib', '/perl/lib', '/more' ] } ),
      ['first-line=T: the search path of modules holds an entry that prove lacks'], 'one more entry';
    is $found->( { env => {} }, { env => {} } ),
      ['every first line: the tool leaves out the variable HARNESS_ACTIVE of prove'],
      'a variable that every test lacks';
    is $found->( { env => { HARNESS_ACTIVE => 0, MORE => 1 } } ),
      [
        'first-line=T: the tool adds the variable MORE',
        'first-line=T: the variable HARNESS_ACTIVE differs from the one of prove',
      ],
      'another value and one more variable';
    is $found->( { taint => undef } ), ['first-line=T: the test leaves no state under the tool'],
      'a test without a state';
};

# The library switch of prove comes first.
# A finding of that launch says nothing new under another launch, and each other finding names its launch.
my $bench  = Discovery::Probe::bench();
my $engine = Discovery::Engine->new;
my @found  = Discovery::Probe::compared( $engine, $bench, 'library' );
my %plain  = map  { $_ => 1 } @found;
my @others = grep { $_ ne 'library' } Discovery::Probe::launches();
for my $launch (@others) {
    push @found,
      map { "launch=$launch, $_" } grep { !$plain{$_} } Discovery::Probe::compared( $engine, $bench, $launch );
}
Discovery::Tier::report( 'baseline', { fast => \@found } );

my @lines = Discovery::Probe::first_lines();
is $bench->{observed}, { 'library' => scalar @lines, 'separate-include' => 2, 'explicit-taint' => 1, 'proverc' => 2 },
  'every test of every launch wrote its state under prove and under the tool';
Gate::checked( 'spellings of a first line', scalar @lines,      at_least => 9 );
Gate::checked( 'launches',                  1 + scalar @others, at_least => 4 );

done_testing;
