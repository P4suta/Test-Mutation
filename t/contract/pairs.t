use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Fixture qw(copy_of write_file);
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::Runner;

# S2, the pairs: every two settings on one command line of `run`, under every state of the environment.
# One setting changes what another does only where a table declares it, and the tables of today declare nothing for two settings.

my $project = copy_of('calc');
write_file( "$project/ci.toml", "\n" );
my @flags        = Space::flags()->@*;
my @environments = Space::environments()->@*;
my ( %violations, %plain, @broken );
my $count = 0;

sub violation ( $gate, $dimension, $what, $one, $environment ) {
    push $violations{$gate}{$dimension}->@*, [ $what, $one, $environment ];
    return;
}

# The settings that a command line of `run` plans, as texts, or nothing for a refusal.
sub planned ( $fact, @words ) {
    my $observation = World::observe( [ 'run', @words ], cwd => $project, $fact->%*, run => 'cheap' );
    push @broken, "@words: $observation->{died}" if defined $observation->{died};
    my $plan = $observation->{plan};
    return $plan && !$plan->{refused} ? Space::config_text( $plan->{config} ) : undef;
}

subtest 'the comparison of a pair rejects a setting that the other one changes' => sub {
    my $base  = planned( {} );
    my $jobs  = planned( {}, '--jobs', 2 );
    my $cache = planned( {}, '--cache' );
    is [ Invariants::independent( $base, $jobs, $cache, planned( {}, '--jobs', 2, '--cache' ) ) ], [],
      'two settings side by side';
    is [ Invariants::independent( $base, $jobs, $cache, planned( {}, '--jobs', 5, '--cache' ) ) ], ['jobs'],
      'a plan with another value than the one that the setting gives alone';
    is [ Invariants::independent( $base, $jobs, $cache, planned( {}, '--jobs', 0, '--cache' ) ) ],
      ['the pair is refused'],
      'a plan that is refused';
};

for my $environment (@environments) {
    my ( $label, $fact ) = $environment->@{qw(label fact)};
    my $base   = planned($fact);
    my %single = map { $_->flag => planned( $fact, Space::flag_words($_)->@* ) } @flags;
    %plain = ( base => $base, %single ) if $label eq 'plain';

    # The environment changes the plan where a table declares it, and nowhere else.
    my $declared = Space::declared( $environment->{named}, 'attributes' );
    violation( 'independent', 'attributes', 'the environment changes a setting that no table declares', $_, $label )
      for grep { !$declared->{$_} && $base->{$_} ne $plain{base}{$_} } sort keys $base->%*;
    for my $setting ( grep { defined $_->attribute } @flags ) {
        my ( $flag, $attribute ) = ( $setting->flag, $setting->attribute );
        violation( 'independent', 'flags', 'the environment changes the value that a flag sets', $flag, $label )
          if $single{$flag}{$attribute} ne $plain{$flag}{$attribute};
    }

    for my $earlier ( 0 .. $#flags ) {
        for my $later ( $earlier + 1 .. $#flags ) {
            my ( $one, $other ) = @flags[ $earlier, $later ];
            my $pair  = join q{+}, $one->flag, $other->flag;
            my @words = ( Space::flag_words($one), Space::flag_words($other) );
            my $both  = planned( $fact, map { $_->@* } @words );
            $count++;
            for my $differs ( Invariants::independent( $base, $single{ $one->flag }, $single{ $other->flag }, $both ) )
            {
                my $what =
                    $differs eq 'the pair is refused'
                  ? $differs
                  : "another value of $differs than its settings give alone";
                violation( 'independent', 'pairs', $what, $pair, $label );
            }

            # The order of two settings is a question of the command line alone, so one state of the environment answers it.
            next if $label ne 'plain' || !$both;
            my $swapped = planned( $fact, map { $_->@* } reverse @words );
            violation( 'independent', 'pairs', 'the order of two settings changes the plan', $pair, $label )
              if !$swapped || Space::differences( $both, $swapped )->@*;
        }
    }
}

my $pairs = 0;
$pairs += $_ for 0 .. $#flags;
is \@broken, [],                     'no plan dies';
is $count,   @environments * $pairs, 'every pair of flags under every state of the environment';
Gate::checked( 'pairs of settings', $count, at_least => 1800 );

subtest 'the output of a run under every state of the environment' => sub {
    my $result = Samples::result( statuses => [qw(Killed Survived)] );
    my %output;
    for my $environment (@environments) {
        no warnings 'redefine';
        local *Test::Mutation::Runner::run = sub ( $config, $listener ) {
            $listener->( 'analyzed', { mutants => 2, files => 1, tests => 1 } );
            $listener->( 'mutant',   { status  => $_->{status} } ) for $result->entries->@*;
            return $result;
        };
        my $observation =
          World::observe( [ 'run', '--format', 'terminal' ], cwd => $project, $environment->{fact}->%* );
        $output{ $environment->{label} } = $observation;
        is $observation->{exit}, 0, "the run under $environment->{label} succeeds";
        for my $stream (qw(stdout stderr)) {
            my $declared = Space::declared( $environment->{named}, 'streams' );
            violation( 'independent', 'streams', 'the environment changes the output where no table declares it',
                $stream, $environment->{label} )
              if !$declared->{$stream} && $observation->{$stream} ne $output{plain}{$stream};
        }
    }
    isnt $output{terminal}{stderr}, $output{plain}{stderr}, 'a terminal gets another progress than a log';
};

my $found = $violations{independent} || {};
Gate::findings( 'contract-independent-pairs',
    [ map { Space::folded( $found->{$_}, $_, 'environments' )->@* } sort keys $found->%* ] );

done_testing;
