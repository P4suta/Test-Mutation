use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(write_file);
use Test::Mutation::Runner;
use Test::Mutation::Settings;

my $use_number = "use Test::More tests => 1;\nuse Number;\nmy \$number = Number::next_number(2);\n";
my $weak       = $use_number . "pass 'the call completed';\n";
my $strong     = $use_number . "is \$number, 3, 'the next number';\n";

sub project (%tests) {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/lib/Number.pm", "package Number;\nsub next_number { return \$_[0] + 1 }\n1;\n" );
    write_file( "$root/$_",            $tests{$_} ) for sort keys %tests;
    return $root;
}

sub config ( $root, %settings ) {
    return Test::Mutation::Settings::of_call( { root => $root, jobs => 1, cache => 0, equivalence => 0, %settings } );
}

sub arithmetic_id ($config) {
    my ($addition) = grep { $_->original eq '+' } Test::Mutation::Runner::analyze($config)->{mutants}->@*;
    return $addition->id;
}

sub entry ( $result, $id ) {
    my ($match) = grep { $_->{mutant}->id eq $id } $result->entries->@*;
    return $match;
}

subtest 'a suggested detector must kill the current mutant in a fresh measurement' => sub {
    my $root   = project( 't/a.t' => $weak, 't/z.t' => $strong );
    my $config = config($root);
    my $id     = arithmetic_id($config);
    my $result = Test::Mutation::Runner::run( $config, sub { }, { detector_hints => { $id => 't/z.t' } } );
    my $found  = entry( $result, $id );
    is $result->stats->{baseline_tests},       2, 'the original tests ran in the current checkout';
    is $result->reused,                        0, 'the measurement reused no verdict';
    is [ $found->@{qw(status by tests_run)} ], [ 'Killed', 't/z.t', 1 ], 'only the proposed detector ran on the mutant';
    is $found->{covered_by},                   [qw(t/a.t t/z.t)], 'the report retains all current covering tests';
    like $found->{observations}, [ [ hash { field test => 't/z.t'; field result => 'fail'; field served => 1; etc } ] ],
      'the changed target was served to the test that failed';
};

subtest 'absent and unreached detectors leave the current covering test order intact' => sub {
    my $root   = project( 't/a.t' => $weak, 't/m.t' => "use Test::More tests => 1;\npass;\n", 't/z.t' => $strong );
    my $config = config($root);
    my $id     = arithmetic_id($config);
    for my $hint (qw(t/deleted.t t/m.t)) {
        my $result = Test::Mutation::Runner::run( $config, sub { }, { detector_hints => { $id => $hint } } );
        my $found  = entry( $result, $id );
        is [ map { $_->{test} } $found->{observations}[0]->@* ], [qw(t/a.t t/z.t)],
          "$hint provided no current coverage";
    }
};

subtest 'a stale detector that passes leaves the usual test order and workspace intact' => sub {
    my $root = project(
        't/a.t' => $use_number . "ok !-e 'from-hint', 'the test starts from the baseline';\n",
        't/b.t' => $strong,
        't/z.t' => $use_number . <<'PERL',
if (!defined($number) || $number != 3) {
    open my $marker, '>', 'from-hint' or die $!;
    close $marker or die $!;
}
pass 'the obsolete detector accepts the change';
PERL
    );
    my $config = config($root);
    my $id     = arithmetic_id($config);
    my $result = Test::Mutation::Runner::run( $config, sub { }, { detector_hints => { $id => 't/z.t' } } );
    my $found  = entry( $result, $id );
    is [ $found->@{qw(status by)} ], [ 'Killed', 't/b.t' ], 'the current assertion determines the verdict';
    is [ map { $_->{test} } $found->{observations}[0]->@* ], [qw(t/a.t t/b.t)],
      'the ordinary measurement starts again at the first covering test';
};

subtest 'a suggested detector may precede parallel tests and must wait for serial tests' => sub {
    for my $rule ( [ par => 't/z.t' ], [ seq => 't/a.t' ], ) {
        my ( $mode, $first ) = @$rule;
        my $root = project(
            'testrules.yml' => "---\n$mode:\n  - 't/a.t'\n  - 't/z.t'\n",
            't/a.t'         => $strong,
            't/z.t'         => $strong,
        );
        my $config = config($root);
        my $id     = arithmetic_id($config);
        my $result = Test::Mutation::Runner::run( $config, sub { }, { detector_hints => { $id => 't/z.t' } } );
        is entry( $result, $id )->{by}, $first, "$mode selects an eligible detector";
    }
};

done_testing;
