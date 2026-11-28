use strict;
use warnings;
use Config ();
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
my $named    = 'e' . unpack( 'H*', 'COMPILER_CONFIG' );
my $operands = join q{,}, 'f' . unpack( 'H*', 'literal input' ), $named;
my @lines    = @{ compile_record( $root, 'stable', $operands, COMPILER_CONFIG => $config ) || [] };
is pop(@lines), q{.}, 'the compiler terminates the complete input record';
my %lines = map { $_ => 1 } @lines;
ok $lines{ unpack 'H*', $literal }, 'the compiler records the absolute path of a literal read';
ok $lines{ unpack 'H*', $config },  'the compiler records the file named by the environment';

my $other = write_file( "$root/other config", "replacement\n" );
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    $ENV{COMPILER_CONFIG} = $ENV{REPLACEMENT_CONFIG};
    open my $input, '<', $ENV{COMPILER_CONFIG} or die "open replacement: $!";
    die "wrong replacement" unless <$input> eq "replacement\n";
}
PERL
ok !defined compile_record( $root, 'rebound', $named, COMPILER_CONFIG => $config, REPLACEMENT_CONFIG => $other ),
  'rebinding an environment operand to another readable file leaves no record';
ok !defined compile_record(
    $root, 'unavailable', $named,
    COMPILER_CONFIG    => "$root/missing",
    REPLACEMENT_CONFIG => $other
  ),
  'an initially unavailable operand cannot acquire evidence later in compilation';

my $library = "$root/vendor";
my $loaded  = write_file( "$library/LibraryInput.pm",    "package LibraryInput; sub value { 5 } 1;\n" );
my $direct  = write_file( project() . '/DirectInput.pm', "package DirectInput; sub value { 7 } 1;\n" );
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    unshift @INC, 'vendor';
    require LibraryInput;
    require $ENV{DIRECT_MODULE};
    die "wrong modules" unless LibraryInput::value() + DirectInput::value() == 12;
}
PERL
my %modules = map { $_ => 1 } @{ compile_record( $root, 'modules', q{}, DIRECT_MODULE => $direct ) || [] };
ok $modules{ unpack 'H*', $library },         'a directory added to the compiler search path is an input';
ok $modules{ 'm' . unpack( 'H*', $loaded ) }, 'a module in the added directory has a source record';
ok !$modules{ unpack 'H*', $loaded },         'the containing directory covers its module path';
ok $modules{ 'm' . unpack( 'H*', $direct ) } && $modules{ unpack 'H*', $direct },
  'a module outside the search path is both a source record and a file input';
ok !$modules{ unpack 'H*', lib_dir() }, 'the initial search directory is already known';
ok !$modules{ 'm' . unpack( 'H*', $INC{'Config.pm'} ) }, 'a Perl core module needs no source record';
ok !$modules{ 'm' . unpack( 'H*', lib_dir() . '/Test/Mutation/CompilerInputs.pm' ) },
  'the recorder excludes its own source';

done_testing;
