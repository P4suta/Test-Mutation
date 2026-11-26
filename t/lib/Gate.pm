package Gate;
use v5.36;
use Test2::API qw(context intercept);

# The outcome of every assertion that a piece of test code makes, for a subtest that expects a rejection.
sub outcomes ($code) {
    my @facets = map { $_->facet_data } intercept { $code->() }->@*;
    return [ map { $_->{assert}{pass} ? 'pass' : 'fail' } grep { $_->{assert} } @facets ];
}

# A gate that checked nothing passes for the wrong reason, so every gate states its count and a floor.
sub checked ( $what, $count, %arg ) {
    die "checked needs a floor: at_least\n" if !defined $arg{at_least};
    my $context = context();
    my $enough  = $count >= $arg{at_least} ? 1 : 0;
    $context->ok( $enough, "the gate checked $count $what, at least $arg{at_least}" );
    $context->release;
    return $enough;
}

sub findings ( $gate, $found ) {
    my $context = context();
    my $clear   = $found->@* ? 0 : 1;
    $context->ok( $clear, "$gate reports no violations", [ sort $found->@* ] );
    $context->release;
    return $clear;
}

1;
