use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture        qw(ran run_fixture write_file);
use Test::Mutation ();
use Test::Mutation::Store;
use Test::Mutation::Report::Json;

my $root  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $adder = "package Adder;\nsub add_one { return \$_[0] + 1 }\n1;\n";
write_file( "$root/lib/Adder.pm", $adder );
write_file( "$root/t/add.t",      <<'PERL' );
use strict;
use warnings;
use Test::More tests => 1;
use Adder;
my $passed = Adder::add_one(2) == 3;
if (!$passed) {
    my $path = $ENV{OBSERVATIONS};
    open my $input, '<', $path or die "read $path: $!";
    my @answers = <$input>;
    close $input or die "close $path: $!";
    my $answer = shift @answers;
    if (!defined $answer) {
        kill 'TERM', getppid() or die "cannot end an extra attempt";
        die "ran out of observations";
    }
    open my $output, '>', $path or die "write $path: $!";
    print {$output} @answers;
    close $output or die "close $path: $!";
    if ($answer eq "interrupt\n") {
        kill 'TERM', $ENV{DRIVER_PID} or die "cannot interrupt the driver";
        sleep 30;
    }
    $passed = $answer eq "pass\n";
    if ($ENV{MARK_COPY}) {
        $passed = 0 if -e 'attempt.marker';
        open my $marker, '>', 'attempt.marker' or die "write marker: $!";
        close $marker or die "close marker: $!";
    }
}
ok $passed, 'add one';
PERL

my ($mutant) = grep { $_->original eq '+' } Test::Mutation::mutants( root => $root )->@*;
my $id       = $mutant->id;
my $outside  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
local $ENV{OBSERVATIONS} = "$outside/observations";
my %settings = ( jobs => 1, cache => 1, equivalence => 0, mutant => [$id] );

for my $order ( [qw(pass fail)], [qw(fail pass)] ) {
    write_file( $ENV{OBSERVATIONS}, join q{}, map { "$_\n" } $order->@* );
    my ( $result, $events ) = run_fixture( $root, %settings );
    my ($entry) = $result->entries->@*;
    is [ $entry->@{qw(status reason tests_run)} ], [ 'NoVerdict', 'unstable-test', 2 ], "@$order is inconclusive";
    like $entry->{detail}, qr/t\/add\.t/, 'the entry names the test';
    like $entry->{detail}, qr/pass/i,     'the entry names the passing observation';
    like $entry->{detail}, qr/fail/i,     'the entry names the failing observation';
    my $portable =
      Test::Mutation::Report::Json::parse( Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ) );

    for my $observed ( $entry, $portable->entries->[0] ) {
        is [
            map {
                [ map { [ $_->@{qw(test result served)} ] } @$_ ]
            } @{ $observed->{observations} || [] }
          ],
          [ map { [ [ 't/add.t', $_, 1 ] ] } @$order ],
          'the API and serialized report retain the evidence of both attempts in order';
    }
    ok !$result->conclusive, 'the run cannot give a score';
    is $result->tally->{valid},                       0, 'the mixed verdict contributes nothing to the score';
    is scalar( grep { $_ eq 'mutant' } $events->@* ), 1, 'one progress event for the final result';
    is $result->reused,                               0, 'both attempts run';
    is Test::Mutation::Store::load("$root/.mutation/measurement.sqlite"), {}, 'the cache has no entry to reuse';
}

write_file( $ENV{OBSERVATIONS}, "fail\npass\n" );
my $command = ran( 4, $root, 'run', '--jobs', 1, '--mutant', $id, '--format', 'terminal', '--no-equivalence' );
like $command->{stdout}, qr/No verdict/i, 'the terminal report identifies the mixed verdict';
like $command->{stdout}, qr/t\/add\.t/,   'the terminal report names the test to reproduce';

for my $case ( [ 'pass', 'Survived' ], [ 'fail', 'Killed' ] ) {
    my ( $answer, $status ) = $case->@*;
    my $cache_dir = ".cache-$answer";
    write_file( $ENV{OBSERVATIONS}, "$answer\n" x 4 );
    my ($cold) = run_fixture( $root, %settings, cache_dir => $cache_dir );
    my ($warm) = run_fixture( $root, %settings, cache_dir => $cache_dir );
    is [ $cold->entries->[0]->@{qw(status tests_run)} ], [ $status, 2 ], "two observations confirm $status";
    is $warm->reused,                                    0, "a request to reproduce $status makes fresh observations";
    is [ $warm->entries->[0]->@{qw(status tests_run)} ], [ $status, 2 ], 'the warm run repeats both attempts';
    write_file( $ENV{OBSERVATIONS}, "pass\n" x 16 );
    my ($bulk)     = run_fixture( $root, %settings, mutant => [], cache_dir => $cache_dir );
    my ($observed) = grep { $_->{mutant}->id eq $id } $bulk->entries->@*;
    is $observed->{status}, 'Survived', 'the bulk run reports the fresh passing observation';

    if ( $answer eq 'pass' ) {
        ok $bulk->reused >= 1, 'the verified passing verdict can be reused';
    }
    else {
        is $bulk->reused, 0, 'the failing verdict is discarded after the sample passes';
        ok $bulk->cache_mismatch, 'the discrepancy prevents the bulk run from passing the gate';
    }
    write_file( $ENV{OBSERVATIONS}, "pass\nfail\n" );
    my ($mixed) = run_fixture( $root, %settings, cache_dir => $cache_dir );
    is $mixed->entries->[0]{status}, 'NoVerdict', 'new conflicting observations supersede the cached verdict';
    ok !exists Test::Mutation::Store::load("$root/$cache_dir/measurement.sqlite")->{$id},
      'the stale verdict is evicted';
}

subtest 'an interruption in the second attempt keeps the mutant pending' => sub {
    local $ENV{DRIVER_PID} = $$;
    write_file( $ENV{OBSERVATIONS}, "fail\ninterrupt\n" );
    my ($partial) = run_fixture( $root, %settings );
    is $partial->interrupted,                               'TERM',           'the run reports the signal';
    is [ $partial->entries->[0]->@{qw(status tests_run)} ], [ 'Pending', 1 ], 'only the completed attempt counts';
    ok !exists Test::Mutation::Store::load("$root/.mutation/measurement.sqlite")->{$id},
      'the initial failure stays out of the cache';
};

subtest 'each attempt starts in a restored or replacement copy' => sub {
    local $ENV{MARK_COPY} = 1;
    Test::Mutation::Tree::restore( from => $root, to => $root, changes => [] );
    my $restore = \&Test::Mutation::Tree::restore;
    for my $discard ( 0, 1 ) {
        my $calls = 0;
        no warnings 'redefine';
        local *Test::Mutation::Tree::restore = sub {
            $calls++;
            die "injected restoration failure\n" if $discard && $calls == 1;
            return $restore->(@_);
        };
        write_file( $ENV{OBSERVATIONS}, "pass\npass\n" );
        my ($result) = run_fixture( $root, %settings, cache => 0 );
        is [ $result->entries->[0]->@{qw(status tests_run)} ], [ 'Survived', 2 ],
          'both attempts loaded the mutant with a clean starting tree';
        is $calls,                   2,            'the runner restores a changed copy after each attempt';
        is $result->stats->{copies}, 2 + $discard, 'only a failed restoration needs a replacement';
    }
    my $attempt = 0;
    no warnings 'redefine';
    local *Test::Mutation::Tree::restore = sub {
        die "second restoration failed\n" if ++$attempt == 2;
        return $restore->(@_);
    };
    write_file( $ENV{OBSERVATIONS}, "pass\npass\n" );
    my ($result) = run_fixture( $root, %settings, cache => 0 );
    is [ $result->entries->[0]->@{qw(status reason)} ], [ 'NoVerdict', 'slot-not-restored' ],
      'an unrecovered final restoration failure makes the verdict inconclusive';
};

subtest 'a nested measurement still observes changes to its enclosing project' => sub {
    my $outer = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $inner = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$outer/lib/Adder.pm", $adder );
    write_file( "$inner/lib/Scale.pm", "package Scale;\nsub double { return \$_[0] * 2 }\n1;\n" );
    write_file( "$inner/t/scale.t",    <<'TEST' );
use Test::More tests => 2;
use Adder;
use Scale;
is Adder::add_one(2), 3, 'the dependency adds one';
is Scale::double(3), 6, 'the inner project doubles its input';
TEST
    write_file( "$outer/t/nested.t", <<'TEST' );
use Test::More tests => 1;
use Cwd ();
use lib $ENV{NESTED_DRIVER_LIB};
use Test::Mutation ();
my $measured = Test::Mutation::run(
    root => $ENV{NESTED_PROJECT}, jobs => 1, cache => 0, equivalence => 0,
    lib => [ 'lib', Cwd::abs_path('lib') ], mutant => [$ENV{NESTED_MUTANT}],
);
my ($inner) = $measured->entries->@*;
is_deeply [ scalar $measured->baseline_failures->@*, $inner ? $inner->@{qw(status by tests_run)} : () ],
  [ 0, 'Killed', 't/scale.t', 2 ], 'the inner project passes with the original dependency and detects its own change';
TEST
    my ($scale) = grep { $_->original eq '*' } Test::Mutation::mutants( root => $inner )->@*;
    local $ENV{NESTED_DRIVER_LIB} = Cwd::abs_path('lib');
    local $ENV{NESTED_PROJECT}    = $inner;
    local $ENV{NESTED_MUTANT}     = $scale->id;
    my ($measured) = run_fixture( $outer, %settings, cache => 0 );
    is $measured->baseline_failures, [], 'the inner measurement succeeds during the outer baseline';
    my ($entry) = $measured->entries->@*;
    is [ $entry->{mutant}->id, $entry->@{qw(status by tests_run)} ], [ $id, 'Killed', 't/nested.t', 2 ],
      'the outer test detects its dependency change through both nested test processes';
};

subtest 'the cache distinguishes the hash traversal settings of the child interpreter' => sub {
    local $ENV{PERL_HASH_SEED}    = '01';
    local $ENV{PERL_PERTURB_KEYS} = '0';
    my %cache = ( %settings, mutant => [], cache_dir => '.hash-cache' );
    write_file( $ENV{OBSERVATIONS}, "pass\n" x 64 );
    my ($first) = run_fixture( $root, %cache );
    is $first->reused,                  0, 'cold cache';
    is $first->entries->[0]{tests_run}, 1, 'the full run observes each candidate once';
    local $ENV{PERL_HASH_SEED} = '02';
    my ($seed) = run_fixture( $root, %cache );
    is $seed->reused, 0, 'another seed needs its own result';
    local $ENV{PERL_PERTURB_KEYS} = '2';
    my ($traversal) = run_fixture( $root, %cache );
    is $traversal->reused, 0, 'another traversal mode needs its own result';
    my ($same) = run_fixture( $root, %cache );
    is $same->reused, scalar $same->entries->@*, 'unchanged traversal inputs reuse the results';
};

subtest 'the original passes under two hash orders that detect the same mutant differently' => sub {
    my $keys = 'my %modules = map { $_ => 1 } qw(A B C D E F G H); my ($first) = keys %modules;';
    my %seed_for;
    local $ENV{PERL_PERTURB_KEYS} = '0';
    for my $number ( 1 .. 128 ) {
        local $ENV{PERL_HASH_SEED} = sprintf '%02x', $number;
        open my $child, '-|', $^X, '-e', "$keys print \$first" or die "start Perl: $!";
        my $first = readline $child;
        close $child or die "Perl exited with $?";
        $seed_for{$first} = $ENV{PERL_HASH_SEED};
        last if keys %seed_for == 2;
    }
    is scalar keys %seed_for, 2, 'separate Perl processes select two different first keys';
    my ( $passes, $fails ) = sort keys %seed_for;
    return if !defined $fails;
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$project/lib/Adder.pm", "package Adder;\nsub add_one { return \$_[0] + 1 }\n1;\n" );
    write_file( "$project/t/order.t",
            "use Test::More tests => 1;\nuse Adder;\n$keys\n"
          . "ok Adder::add_one(2) == 3 || \$first eq '$passes', 'version lookup';\n" );
    for my $case ( [ $passes, 'Survived' ], [ $fails, 'Killed' ] ) {
        local $ENV{PERL_HASH_SEED} = $seed_for{ $case->[0] };
        my ($observed) = run_fixture( $project, %settings, cache => 0 );
        is $observed->baseline_failures, [], 'the original passes under the chosen traversal';
        is [ $observed->entries->[0]->@{qw(status tests_run)} ], [ $case->[1], 2 ],
          "both fresh attempts give $case->[1] under the chosen traversal";
    }
};

done_testing;
