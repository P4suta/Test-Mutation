package Discovery::Tier;
use v5.36;
use Test2::API qw(context);
use lib 't/lib';
use Gate;

# The fast tier runs every axis value once on each change, and the full tier adds the seeds and the products.
# DISCOVERY_SEED selects a reproducible set of inputs.

my $SEED = 1;

sub name () {
    my $tier = defined $ENV{DISCOVERY_TIER} ? $ENV{DISCOVERY_TIER} : 'fast';
    die "DISCOVERY_TIER names no tier: $tier\n" if $tier ne 'fast' && $tier ne 'full';
    return $tier;
}

sub full () {
    return name() eq 'full' ? 1 : 0;
}

sub seed () {
    my $seed = defined $ENV{DISCOVERY_SEED} ? $ENV{DISCOVERY_SEED} : $SEED;
    die "DISCOVERY_SEED is no number: $seed\n" if $seed !~ /\A[0-9]+\z/;
    return 0 + $seed;
}

sub announce () {
    my $context = context();
    $context->note( sprintf 'DISCOVERY_SEED=%d DISCOVERY_TIER=%s', seed(), name() );
    $context->release;
    return;
}

# The cases of the fast tier, and after them the cases that the full tier alone runs.
sub cases ( $fast, $more ) {
    return ( ( map { [ 'fast', $_ ] } $fast->@* ), ( full() ? map { [ 'full', $_ ] } $more->@* : () ) );
}

# Report each violation in the first tier that reaches it.
sub report ( $harness, $found ) {
    my %fast = map { $_ => 1 } @{ $found->{fast} || [] };
    my $ok   = Gate::findings( "engine-$harness", [ sort keys %fast ] );
    return $ok if !full();
    my %more = map { $_ => 1 } grep { !$fast{$_} } @{ $found->{full} || [] };
    return Gate::findings( "engine-$harness-full", [ sort keys %more ] ) && $ok;
}

1;
