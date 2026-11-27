use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Merge;
use Test::Mutation::Report::Json;
use Test::Mutation::Runner;
use Test::Mutation::Settings;

my $area    = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $library = "$area/external";
local $ENV{TEST_PROJECT_LIBRARY} = $library;
local $ENV{TEST_PROJECT_LIMIT}   = 5;
my $module   = "package Boundary; sub positive { return \$_[0] > 0 } 1;\n";
my $external = "package Defaults; sub count () { 3 } 1;\n";
my $test     = <<'PERL';
use Test::More tests => 1;
use lib $ENV{TEST_PROJECT_LIBRARY};
use Defaults;
use Boundary;
open my $file, '<', 'limit.dat' or die $!;
my $limit = <$file>;
close $file or die $!;
ok Boundary::positive(Defaults::count()) && Defaults::count() <= $limit && $ENV{TEST_PROJECT_LIMIT} > 0;
PERL
for my $checkout (qw(first second)) {
    my $root = "$area/$checkout";
    write_file( "$root/lib/Boundary.pm", $module );
    write_file( "$root/lib/Other.pm",    "package Other; sub value { 9 } 1;\n" );
    write_file( "$root/t/boundary.t",    $test );
    write_file( "$root/limit.dat",       "4\n" );
    my $program = write_file( "$root/tools/perl", "#!$^X\nexec {q{$^X}} q{$^X}, \@ARGV or die \$!;\n" );
    chmod 0755, $program or die $!;
}
write_file( "$library/Defaults.pm", $external );

sub checkout_library ( $checkout, $part ) {
    local $ENV{PERL5LIB} = join q{:}, "$area/$checkout/lib", grep { defined } $ENV{PERL5LIB};
    return shard( $checkout, $part );
}

sub shard ( $root, $part, %settings ) {
    my ($result) = run_fixture( "$area/$root", shard => "$part/2", cache => 0, %settings );
    return { name => $root, result => $result };
}

my $first = shard( 'first', 1 );

sub compare (%settings) {
    my $other = shard( 'second', 2, %settings );
    return Test::Mutation::Merge::merge( [ $first, $other ] );
}

ok lives { compare( cache => 1, jobs => 1 ) }, 'cached and uncached observations use compatible inputs';
ok lives { Test::Mutation::Merge::merge( [ checkout_library( 'first', 1 ), checkout_library( 'second', 2 ) ] ) },
  'checkout-relative Perl search paths identify identical project libraries';
{
    my @parts;
    for my $number ( 1 .. 2 ) {
        my $root   = "$area/" . ( $number == 1 ? 'first' : 'second' );
        my $config = Test::Mutation::Settings::of_call( { root => $root, shard => "$number/2", cache => $number - 1 } );
        my $result = Test::Mutation::Runner::run( $config, sub { }, { paths => { 'lib/Boundary.pm' => [] } } );
        push @parts, { name => "$number", result => $result };
    }
    ok lives { Test::Mutation::Merge::merge( \@parts ) }, 'both cache modes identify the same file selection';
}
{
    local $ENV{TEST_PROJECT_LIMIT} = 7;
    like dies { compare() }, qr/measurement inputs differ/, 'the test environment binds each measurement';
}
write_file( "$area/second/limit.dat", "5\n" );
like dies { compare() }, qr/measurement inputs differ/, 'data read by the tests belongs to the measurement';
write_file( "$area/second/limit.dat", "4\n" );
write_file( "$library/Defaults.pm",   $external =~ s/\b3\b/2/r );
like dies { compare() }, qr/measurement inputs differ/, 'an external dependency loaded by an uncached run counts';
write_file( "$library/Defaults.pm", $external );

subtest 'standalone compilation uses the same external libraries across shards' => sub {
    my $idle = <<'PERL';
package Idle;
use lib $ENV{TEST_PROJECT_LIBRARY};
use Defaults;
sub small { return $_[0] < Defaults::count() }
sub large { return $_[0] > Defaults::count() }
1;
PERL
    for my $checkout (qw(idle-first idle-second)) {
        write_file( "$area/$checkout/lib/Idle.pm", $idle );
        write_file( "$area/$checkout/t/pass.t",    "use Test::More tests => 1; pass 'ready';\n" );
    }
    my $start = shard( 'idle-first',  1, cache => 1 );
    my $end   = shard( 'idle-second', 2, cache => 1 );
    ok + ( grep { defined $_->{compiled_digest} } $start->{result}->entries->@* ),
      'the first shard compares compiled code';
    ok + ( grep { defined $_->{compiled_digest} } $end->{result}->entries->@* ),
      'the second shard compares compiled code';
    ok lives { Test::Mutation::Merge::merge( [ $start, $end ] ) }, 'equal compiler inputs produce compatible shards';
    write_file( "$library/Defaults.pm", $external =~ s/\b3\b/7/r );
    like dies { Test::Mutation::Merge::merge( [ $start, shard( 'idle-second', 2, cache => 1 ) ] ) },
      qr/measurement inputs differ/, 'a cached shard checks the library loaded only by the compiler';
    like dies { Test::Mutation::Merge::merge( [ $start, shard( 'idle-second', 2 ) ] ) },
      qr/measurement inputs differ/, 'a fresh shard binds the library loaded only by the compiler';
    write_file( "$library/Defaults.pm", $external );
    my $link = "$area/compiler-library";
    local $ENV{TEST_PROJECT_LIBRARY} = $link;
    symlink $library, $link or die $!;
    my $linked = shard( 'idle-second', 2, cache => 1 );
    my $json   = Test::Mutation::Report::Json::render( $linked->{result}, high => 80, low => 60 );
    $linked->{result} = Test::Mutation::Report::Json::parse($json);
    ok lives { Test::Mutation::Merge::merge( [ $linked, shard( 'idle-first', 1, cache => 1 ) ] ) },
      'a report keeps its compiler inputs across a JSON round trip';
    write_file( "$area/replacement/Defaults.pm", $external =~ s/\b3\b/8/r );
    unlink $link or die $!;
    symlink "$area/replacement", $link or die $!;
    like dies { Test::Mutation::Merge::merge( [ $linked, shard( 'idle-first', 1, cache => 1 ) ] ) },
      qr/measurement inputs differ/, 'a cached compiler checks the current target of a library link';
    like dies { Test::Mutation::Merge::merge( [ $linked, shard( 'idle-first', 1 ) ] ) },
      qr/measurement inputs differ/, 'a fresh compiler identifies the library by its search path';
};

subtest 'data opened during compilation identifies cached and merged verdicts' => sub {
    my $idle = <<'PERL';
package Idle;
BEGIN {
    open my $input, '<', $ENV{TEST_PROJECT_TABLE} or die $!;
    my $number = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('LIMIT', $number);
}
sub small { return $_[0] < LIMIT }
sub large { return $_[0] > LIMIT }
1;
PERL
    for my $checkout (qw(data-first data-second)) {
        write_file( "$area/$checkout/lib/Idle.pm", $idle );
        write_file( "$area/$checkout/t/pass.t",    "use Test::More tests => 1; pass 'ready';\n" );
    }
    local $ENV{TEST_PROJECT_TABLE} = "$area/limit";
    write_file( "$area/limit", "3\n" );
    my $prior = shard( 'data-first',  1, cache => 1 );
    my $other = shard( 'data-second', 2, cache => 1 );
    ok + ( grep { defined $_->{compiled_digest} } $other->{result}->entries->@* ),
      'a known input permits code comparison';
    ok lives { Test::Mutation::Merge::merge( [ $prior, $other ] ) }, 'equal external data can be combined';
    write_file( "$area/limit", "7\n" );
    my $warm = shard( 'data-second', 2, cache => 1 );
    is $warm->{result}->reused, 0, 'changed compiler data invalidates cached verdicts';
    like dies { Test::Mutation::Merge::merge( [ $prior, $warm ] ) }, qr/measurement inputs differ/,
      'a cached shard must agree with the previous external data';
    like dies { Test::Mutation::Merge::merge( [ $prior, shard( 'data-second', 2 ) ] ) }, qr/measurement inputs differ/,
      'a fresh shard must agree with the previous external data';

    $idle =~
      s{(BEGIN \{)\n(    open[^\n]+)\$ENV\{TEST_PROJECT_TABLE\}}{$1\n    my \$path = \$ENV{TEST_PROJECT_TABLE};\n$2\$path};
    for my $checkout (qw(data-first data-second)) {
        write_file( "$area/$checkout/lib/Idle.pm", $idle );
    }
    my $opaque = shard( 'data-first',  1, cache => 1 );
    my $peer   = shard( 'data-second', 2, cache => 1 );
    is $opaque->{result}->compiler_inputs, $peer->{result}->compiler_inputs,
      'an unchanged opaque source has the same compilation in both checkouts';
    ok !( grep { defined $_->{compiled_digest} } $peer->{result}->entries->@* ),
      'an indirect compiler input leaves the observed test verdict in place';
    ok + ( grep { $_->{status} eq 'NoCoverage' } $peer->{result}->entries->@* ),
      'the untouched target keeps its actual lack of test coverage';
    ok lives { Test::Mutation::Merge::merge( [ $opaque, $peer ] ) }, 'equal observations from opaque sources can merge';
    write_file( "$area/limit", "11\n" );
    my $changed = shard( 'data-second', 2, cache => 1 );
    is $changed->{result}->reused, 0, 'a source with opaque compiler reads is measured again';
    like dies { Test::Mutation::Merge::merge( [ $opaque, $changed ] ) }, qr/measurement inputs differ/,
      'different observed compilations of one opaque source reject the merge';
};

my $wrapped = shard( 'first', 1, perl => 'tools/perl' );
ok lives { Test::Mutation::Merge::merge( [ $wrapped, shard( 'second', 2, perl => 'tools/perl' ) ] ) },
  'identical project-relative interpreters work in separate checkouts';
write_file( "$area/second/tools/perl", "#!$^X\n# another launcher\nexec {q{$^X}} q{$^X}, \@ARGV or die \$!;\n" );
like dies { Test::Mutation::Merge::merge( [ $wrapped, shard( 'second', 2, perl => 'tools/perl' ) ] ) },
  qr/measurement inputs differ/, 'changing a launcher changes the measured environment';

done_testing;
