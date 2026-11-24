package Capability;
use v5.36;
use Test2::API qw(context);

my %KNOWN = map { $_ => 1 } qw(git class second-perl processor-count unprivileged toolchain);

sub decision ( $name, $present, $required ) {
    die "no capability is named $name\n" if !$KNOWN{$name};
    my @required = grep { length } map { s/\A\s+|\s+\z//gr } split /,/, $required;
    my @unknown  = grep { !$KNOWN{$_} } @required;
    die 'TEST_MUTATION_REQUIRE names no capability: ' . join( ', ', @unknown ) . "\n" if @unknown;
    return 'run'                                                                      if $present;
    return ( grep { $_ eq $name } @required ) ? 'fail' : 'skip';
}

# A job that lists a capability in TEST_MUTATION_REQUIRE gets a failure where another machine gets a skip.
sub _decided ( $name, $present, $reason ) {
    my $required = defined $ENV{TEST_MUTATION_REQUIRE} ? $ENV{TEST_MUTATION_REQUIRE} : q{};
    my $decision = decision( $name, $present ? 1 : 0, $required );
    die "TEST_MUTATION_REQUIRE lists $name, and $reason\n" if $decision eq 'fail';
    return $decision;
}

# The whole test file needs the capability.
sub need ( $name, $present, $reason ) {
    return if _decided( $name, $present, $reason ) eq 'run';
    my $context = context();
    $context->plan( 0, SKIP => $reason );
    $context->release;
    return;
}

# One case of a test needs the capability, and the answer tells whether to run it.
sub has ( $name, $present, $reason ) {
    return 1 if _decided( $name, $present, $reason ) eq 'run';
    my $context = context();
    $context->skip( "a case that needs $name", $reason );
    $context->release;
    return 0;
}

1;
