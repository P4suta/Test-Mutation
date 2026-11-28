use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(lib_dir project run_perl write_file);

sub compile_record {
    my ( $root, $name, $operands, %environment ) = @_;
    my $record = "$root/records/$name";
    my $ran    = run_perl(
        root => $root,
        env  => { %environment, TEST_MUTATION_COMPILER_INPUTS => $record, TEST_MUTATION_COMPILER_READS => $operands },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::CompilerInputs', '-c', 'probe.pl' ],
    );
    is $ran->{status}, 0, "$name compiles" or diag $ran->{stderr};
    return unless -f $record;
    open my $in, '<:raw', $record or die "open $record: $!";
    chomp( my @lines = <$in> );
    close $in or die "close $record: $!";
    return \@lines;
}

my $root    = project();
my $literal = write_file( "$root/literal input", "literal\n" );
my $config  = write_file( "$root/config",        "environment\n" );
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    open my $literal, '<', 'literal input' or die "open literal: $!";
    open my $config, '<', $ENV{COMPILER_CONFIG} or die "open config: $!";
    die "wrong inputs" unless <$literal> eq "literal\n" && <$config> eq "environment\n";
}
PERL
my $operands = join q{,}, 'f' . unpack( 'H*', 'literal input' ), 'e' . unpack( 'H*', 'COMPILER_CONFIG' );
my @lines    = @{ compile_record( $root, 'stable', $operands, COMPILER_CONFIG => $config ) || [] };
is pop(@lines), q{.}, 'the compiler terminates the complete input record';
my %lines = map { $_ => 1 } @lines;
ok $lines{ unpack 'H*', $literal }, 'the compiler records the absolute path of a literal read';
ok $lines{ unpack 'H*', $config },  'the compiler records the file named by the environment';

done_testing;
