use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Capability;
use Gate;
use Invariants;
use Space;
use World;
use Test::Mutation::Exit;
use Test::Mutation::Pool;
use Test::Mutation::Tree;

# S4, the selectors: each kind of selector that matches, matches nothing, or is malformed, from each place a user writes it.
# Each case runs the real command in a small project of its own.

Capability::need( 'git', length qx{git --version 2>/dev/null}, 'the cases of --since need the git command' );

# A usage error comes before the first copy and the first test, so each case counts both.
# The first call of a checked subroutine installs its compiled form over the name, so each case wraps the names anew.
sub observed_with_counts ( $argv, $root ) {
    my %started;
    my ( $copy, $pool ) = ( \&Test::Mutation::Tree::copy, \&Test::Mutation::Pool::run );
    no warnings 'redefine';
    local *Test::Mutation::Tree::copy = sub { $started{copies}++; return $copy->(@_) };
    local *Test::Mutation::Pool::run  = sub { $started{tests}++;  return $pool->(@_) };
    return ( World::observe( $argv, cwd => $root ), \%started );
}

my @codes = map { $_->code } Test::Mutation::Exit::rows()->@*;
my ($identifier) = World::observe( ['list'], cwd => Space::tree() )->{stdout} =~ /\A([0-9a-f]{12})  /
  or die "the sample project lists no mutant\n";
my $cases = Space::selections($identifier);
my ( %violations, %seen, @broken );

for my $case ( $cases->@* ) {
    my ( $kind, $origin, $state ) = $case->@{qw(kind origin state)};
    my ( $observation, $started ) = observed_with_counts( $case->{argv}, Space::selection_tree($case) );
    $seen{kind}{$kind} = $seen{origin}{$origin} = $seen{state}{$state} = 1;
    if ( defined $observation->{died} ) {
        push @broken, "$kind $origin $state: $observation->{died}";
        next;
    }
    push @broken, map { "$kind $origin $state: $_" } Invariants::exit_domain( $observation, \@codes );
    my %symptoms = (
        selector    => [ Invariants::selector( $observation, $case->{exit}, $case->{named} ) ],
        'one-line'  => [ Invariants::one_line($observation) ],
        'no-leak'   => [ Invariants::no_leak($observation) ],
        'no-effect' => [ $case->{exit} == 2 ? Invariants::no_effect($started) : () ],
    );
    for my $gate ( sort keys %symptoms ) {
        push $violations{$gate}->@*, map { [ "$state: $_", $kind, $origin ] } $symptoms{$gate}->@*;
    }
}

is \@broken, [], 'no command dies, and every exit status stands in the table';

my ( $expected, %place ) = (0);
for my $selector ( Space::selectors()->@* ) {
    my $row = $selector->{row};
    my @places =
        $selector->{origins}
      ? $selector->{origins}->@*
      : ( ( $row->key ? 'file' : () ), ( defined $row->flag ? 'line' : () ) );
    $place{$_} = 1 for @places, ( $selector->{default} && $selector->{default}->@* ? 'default' : () );
    $expected += Space::states()->@* * @places + ( $selector->{default} ? $selector->{default}->@* : 0 );
}
my @states = Space::states()->@*;
is scalar $cases->@*,               $expected, 'the cases that the table of selectors and the settings table call for';
is [ sort keys $seen{kind}->%* ],   [ sort map { $_->{kind} } Space::selectors()->@* ], 'every kind of selector';
is [ sort keys $seen{origin}->%* ], [ sort keys %place ], 'every place where a user writes a selector';
is [ sort keys $seen{state}->%* ],  [ sort @states ],     'every state';
Gate::checked( 'selections', scalar $cases->@*, at_least => 55 );

for my $gate (qw(selector one-line no-leak no-effect)) {
    Gate::findings( "contract-$gate-selectors", Space::folded( $violations{$gate} || [], 'selectors', 'origins' ) );
}

done_testing;
