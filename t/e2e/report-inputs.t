use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Merge;

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
write_file( "$root/lib/Calc.pm", <<'PERL' );
package Calc;
sub add { my ( $left, $right ) = @_; return $left + $right }
1;
PERL
write_file( "$root/t/add.t", <<'PERL' );
use Test::More tests => 1;
use JSON::PP;
use Calc;
open my $input, '<:raw', 'spec/mutation.json' or die $!;
my $operand = decode_json( readline $input )->{operand};
is Calc::add( 4, $operand ), 4 + $operand, 'adds the operand from the specification';
PERL

sub specification ($value) {
    write_file( "$root/spec/mutation.json", qq[{"framework":{"name":"Test::Mutation"},"operand":$value}] );
    return;
}

sub subtraction ($result) {
    my ($entry) = grep { $_->{mutant}->original eq q{+} && $_->{mutant}->replacement eq q{-} } $result->entries->@*;
    return $entry->{status};
}

specification(0);
my ($before) = run_fixture( $root, cache => 1 );
is subtraction($before), 'Survived', 'adding zero and subtracting zero agree';
my ($first) = run_fixture( $root, cache => 0, shard => '1/2' );
specification(1);
my ($after) = run_fixture( $root, cache => 1 );
is subtraction($after), 'Killed', 'an edited specification changes the cached verdict';
my ($changed_part) = run_fixture( $root, cache => 0, shard => '2/2' );
my @parts = ( { name => 'one', result => $first }, { name => 'two', result => $changed_part } );
like dies { Test::Mutation::Merge::merge( \@parts ) }, qr/measurement inputs differ/,
  'parts measured with different operand data cannot form a single result';

subtest 'an in-place test can read project inputs inside the chosen report directory' => sub {
    my %settings = ( in_place => 1, report_dir => 'spec', jobs => 1 );
    specification(0);
    my ($cached) = run_fixture( $root, cache => 1, %settings );
    my ($part)   = run_fixture( $root, cache => 0, shard => '1/2', %settings );
    is subtraction($cached), 'Survived', 'the in-place test reads its operand from the report directory';
    specification(1);
    my ($rechecked) = run_fixture( $root, cache => 1, %settings );
    is subtraction($rechecked), 'Killed', 'changing a visible operand invalidates the in-place verdict';
    my ($new_part) = run_fixture( $root, cache => 0, shard => '2/2', %settings );
    my @pieces = ( { name => 'before', result => $part }, { name => 'after', result => $new_part } );
    like dies { Test::Mutation::Merge::merge( \@pieces ) }, qr/measurement inputs differ/,
      'in-place shards cannot merge observations from different operands in the report directory';
};

done_testing;
