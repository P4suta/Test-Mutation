use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Fixture qw(write_file);
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::Runner;

# S2, the pairs: every two settings on one command line of `run`, under every state of the environment.
# One setting changes what another does only where the table of the interactions declares it.
# The environment changes a setting only where the table states a default that depends on it.

my $project = Space::tree();
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
    my $hosted = planned( { env => { GITHUB_ACTIONS => 'true' } } );
    is Space::differences( $base, $hosted ),
      ['format: the table says terminal json html, the surface terminal json html github'],
      'a variable of the environment that changes a setting';
    is Space::differences( Space::declared_defaults( {} ),
        Space::declared_defaults( { env => { GITHUB_ACTIONS => 'true' } } ) ),
      ['format: the table says terminal json html, the surface terminal json html github'],
      'and the default of the table that depends on it';
    is Space::flag_words( ( grep { $_->flag eq '--equivalence' } @flags )[0] ), ['--no-equivalence'],
      'a flag that is on by default has its negated form in a pair';
    my %flag = map { $_->flag => $_ } @flags;
    is [
        map { Space::interaction( @flag{ $_->@* } ) } [qw(--in-place --link)], [qw(--link --in-place)],
        [qw(--jobs --link)]
      ],
      [ 'exclusive', 'exclusive', undef ], 'a pair that the table binds, in either order';
};

my $unchanged = Space::declared_defaults( {} );
for my $environment (@environments) {
    my ( $label, $fact ) = $environment->@{qw(label fact)};
    my $base   = planned($fact);
    my %single = map { $_->flag => planned( $fact, Space::flag_words($_)->@* ) } @flags;
    %plain = ( base => $base, %single ) if $label eq 'plain';

    # The environment may change a setting only to the default that the table states for it.
    my $declared = Space::declared_defaults($fact);
    for my $name ( sort keys $base->%* ) {
        my $moved = exists $declared->{$name} && $declared->{$name} ne $unchanged->{$name};
        next if $base->{$name} eq ( $moved ? $declared->{$name} : $plain{base}{$name} );
        violation(
            'independent',
            'attributes',
            $moved
            ? 'the environment changes a setting another way than the table declares'
            : 'the environment changes a setting that no table declares',
            $name,
            $label
        );
    }
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

            # A pair that the table declares exclusive is refused, and every other pair keeps the values of its settings.
            my @found = Invariants::independent( $base, $single{ $one->flag }, $single{ $other->flag }, $both );
            my $rule  = Space::interaction( $one, $other );
            if ( defined $rule && $rule eq 'exclusive' ) {
                violation( 'independent', 'pairs', 'a pair that the table declares exclusive is accepted',
                    $pair, $label )
                  if "@found" ne 'the pair is refused';
                next;
            }
            for my $differs (@found) {
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
        local *Test::Mutation::Runner::run = sub ( $config, $listener, $options ) {
            $listener->( 'analyzed', { mutants => 2, files => 1, tests => 1 } );
            $listener->( 'mutant',   { status  => $_->{status} } ) for $result->entries->@*;
            return $result;
        };
        my $observation =
          World::observe( [ 'run', '--format', 'terminal' ], cwd => $project, $environment->{fact}->%* );
        $output{ $environment->{label} } = $observation;
        is $observation->{exit}, 0, "the run under $environment->{label} succeeds";
        my $facts  = $environment->{fact};
        my $styled = $facts->{out_tty} && !length $facts->{env}{NO_COLOR};
        is !!( $observation->{stdout} =~ /\e\[\d+m/ ), !!$styled,     "color under $environment->{label}";
        is !!( $observation->{stderr} =~ /\r/ ), !!$facts->{err_tty}, "terminal updates under $environment->{label}";

        for my $stream (qw(stdout stderr)) {
            my $rendered = $observation->{$stream} =~ s/\e\[\d+m//gr;
            $rendered =~ s/\r/\n/g;
            $rendered =~ s/\n+/\n/g;
            my $plain = $output{plain}{$stream} =~ s/\n+/\n/gr;
            violation( 'independent', 'streams', 'the environment changes the output where no table declares it',
                $stream, $environment->{label} )
              if $rendered ne $plain;
        }
    }
    isnt $output{terminal}{stderr}, $output{plain}{stderr}, 'a terminal gets another progress than a log';
    Gate::checked( 'runs under a state of the environment', scalar( keys %output ), at_least => 8 );
};

my $found = $violations{independent} || {};
Gate::findings( 'contract-independent-pairs',
    [ map { Space::folded( $found->{$_}, $_, 'environments' )->@* } sort keys $found->%* ] );

done_testing;
