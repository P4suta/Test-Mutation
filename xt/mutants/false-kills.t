use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(copy_of run_fixture);
use Gate;
use Kills;
use Oracle;
use Test::Mutation::Settings;
use Test::Mutation::Host;
use Test::Mutation::Runner;

# A test that fails with a mutant in place counts as a kill, whatever made it fail.
# A kill through a new call, a file without a true value, or code that perl refuses measures no behavior of the code.
# The killing test runs again with the mutant, and its output names the cause.

sub by_hand_kills () {
    my $root   = copy_of('calc');
    my $config = Test::Mutation::Settings::of_call( { root => $root } );
    my $source = Test::Mutation::Runner::analyze($config)->{sources}{'lib/Calc.pm'};
    my @cases  = (
        [ 'return $x + $y', 'return $x - $y',       't/add.t' ],
        [ 'return $x + $y', q{die "broken\n"},      't/add.t' ],
        [ 'return $x + $y', 'return max( $x, $y )', 't/add.t' ],
        [ "\n1;\n",         "\n0;\n",               't/add.t' ],
        [ 'return $x + $y', 'return $x +',          't/add.t' ],
        [ "\n1;\n",         qq{\ndie "no\\n";\n},   't/add.t' ],
        [ 'return $n * 2',  'return $n * 3',        't/add.t' ],
    );
    my @kills;
    for my $case (@cases) {
        my ( $original, $replacement, $test ) = $case->@*;
        push @kills, Kills::judged( $config, $source, Oracle::by_hand( $source, $original, $replacement ), $test );
    }
    return @kills;
}

subtest 'the rerun rejects a kill through a new call, a false file, and code that perl refuses' => sub {
    my @kills = by_hand_kills();
    is [ map { $_->{class} } @kills ],
      [qw(assertion exception resolution untrue compile load-death unreproduced)],
      'each kill built by hand gets the class of its cause';
    is [ Kills::findings(@kills) ],
      [
        'by-hand has a kill that the rerun does not reproduce',
        'by-hand kills through a file without a true value',
        'by-hand kills through an unresolved call',
        'by-hand kills through code that perl refuses',
      ],
      'the false kills are findings, and an assertion, an exception, or a death while the file loads are none';
    is Gate::outcomes( sub { Gate::findings( 'mutants-kills-rejected', [ Kills::findings(@kills) ] ) } ),
      ['fail'], 'a false kill fails the gate';

    my $mutant = $kills[0]{mutant};
    my $called =
      "Undefined subroutine &Calc::helper called at lib/Calc.pm line 7.\n# Looks like your test exited with 255 just after 1.\n";
    is Kills::class_of( $mutant, { status => 255, output => $called }, sub { 1 } ), 'exception',
      'a call without a subroutine that the change did not write is an exception';
    is Kills::class_of( $mutant, { status => 1, output => "1..1\nnot ok 1\n" }, sub { 1 } ), 'assertion',
      'a failed assertion';
    is Kills::class_of( $mutant, { status => 2, output => "1..2\nok 1\n" }, sub { 1 } ), 'exception',
      'a test that ends badly without a failed assertion has thrown';
    is Kills::class_of( $mutant, { timed_out => 1, output => "1..2\nnot ok 1\n" }, sub { 1 } ), 'assertion',
      'a test that runs on after its first failure has the class of that failure';
    is Kills::class_of( $mutant, { timed_out => 1, output => "1..2\n" }, sub { 1 } ), 'timeout',
      'and a test that never fails before the bound stops it has none';
};

sub tallied_ok ( $scope, @kills ) {
    my $tally = Oracle::tally();
    for my $kill (@kills) {
        Oracle::count( $tally, $kill->{mutator}, $_ ) for 'kills', $kill->{class};
    }
    note $_ for Oracle::table( $tally, 'kills', map { "$_:kills" } Kills::classes() );
    my @unclear = grep { $_->{class} eq 'timeout' } @kills;
    is [ map { "$_->{mutator} by $_->{test}: $_->{class}" } @unclear ], [],
      "$scope: every rerun fails before the bound stops it";
    diag $_->{output} for @unclear;
    Gate::findings( "mutants-kills-$scope", [ Kills::findings(@kills) ] );
    return;
}

# Every kill of the fixtures runs again: a run of the tool finds each kill and the test that made it.
# A mutant that broke the compilation or ran out of time has a status of its own, and no test killed it.
# A test of a fixture ends within a second, and a mutant may hold it in a loop after its first failure.
my $FIXTURE_SECONDS = 10;
my ( @fixture_kills, %status );
for my $fixture (qw(calc counter equivalent mechanics)) {
    my $root     = copy_of($fixture);
    my ($result) = run_fixture( $root, profile => 'extended', timeout_floor => 1, timeout_factor => 2 );
    my $config   = Test::Mutation::Settings::of_call( { root => $root } );
    my $sources  = Test::Mutation::Runner::analyze($config)->{sources};
    $status{ $_->{status} }++ for $result->entries->@*;
    push @fixture_kills,
      map { Kills::judged( $config, $sources->{ $_->{mutant}->path }, $_->{mutant}, $_->{by}, $FIXTURE_SECONDS ) }
      grep { $_->{status} eq 'Killed' } $result->entries->@*;
}
note join q{, }, map { "$_ $status{$_}" } sort keys %status;
tallied_ok( 'fixtures', @fixture_kills );
Gate::checked( 'kills of the fixtures that ran again', scalar @fixture_kills, at_least => 60 );

# Elsewhere: a sample of each mutator in the tool itself, under the unit tests that name the module of the mutant.
# The first of those tests that fails with the mutant is the killing test, and a test that fails without it never counts.
# The shim serves every mutant, so a mutant of the shim stays out.
my $SAMPLE  = 3;
my $TESTS   = 3;
my $workers = Test::Mutation::Host::processors()->{count};
my $base    = File::Temp->newdir;
my $own     = Kills::copied( "$base/main", qw(lib t bin) );
my $config  = Test::Mutation::Settings::of_call( { root => $own, profile => 'extended' } );
my $made    = Test::Mutation::Runner::analyze($config);
my @tests   = sort { -s "$own/$a" <=> -s "$own/$b" || $a cmp $b } map { s{\A\Q$own\E/}{}r } glob "$own/t/unit/*.t";
my %text    = map  { $_ => Oracle::file_source("$own/$_")->text } @tests;
my %named;

for my $path ( keys $made->{sources}->%* ) {
    my $package = $path =~ s{\Alib/}{}r =~ s{[.]pm\z}{}r =~ s{/}{::}gr;
    $named{$path} = [ grep { $text{$_} =~ /\Q$package\E(?![\w:])/ } @tests ];
}
my %by_mutator;
for my $mutant ( grep { $_->path ne 'lib/Test/Mutation/Shim.pm' && $named{ $_->path }->@* } $made->{mutants}->@* ) {
    push $by_mutator{ $mutant->mutator }->@*, $mutant;
}
my @chosen = map { Oracle::spread( $by_mutator{$_}, $SAMPLE ) } sort keys %by_mutator;

# Each worker runs the tests in a copy of its own, so two tests never share a tree.
my %passes;
my $records = Oracle::each_file(
    [ map { [ "mutant $_", $_ ] } 0 .. $#chosen ],
    $workers,
    sub ( $label, $index ) {
        my $mutant = $chosen[$index];
        my $root   = -d "$base/$$" ? "$base/$$" : Kills::copied( "$base/$$", qw(lib t bin) );
        my $here   = Test::Mutation::Settings::of_call( { root => $root } );
        my $source = $made->{sources}{ $mutant->path };
        for my $test ( grep { defined } $named{ $mutant->path }->@[ 0 .. $TESTS - 1 ] ) {
            $passes{$test} //= ( Kills::plain( $here, $test )->{status} // 1 ) == 0 ? 1 : 0;
            next if !$passes{$test};
            my $kill = Kills::judged( $here, $source, $mutant, $test );
            next if $kill->{class} eq 'unreproduced';

            # A test that never fails before the bound stops it gives the status Timeout, which is no kill.
            return [ 'hung', $mutant->mutator ] if $kill->{class} eq 'timeout';
            return [ 'kill', $mutant->mutator, $kill->{class}, $test, $kill->{output} ];
        }
        return [ 'survived', $mutant->mutator ];
    }
);
my @own_kills = map { +{ mutator => $_->[2], class => $_->[3], test => $_->[4], output => $_->[5] } }
  grep { $_->[1] eq 'kill' } $records->@*;
my %killed = map { $_->{mutator} => 1 } @own_kills;
my %ended;
$ended{ $_->[1] }++ for $records->@*;
note sprintf '%d mutants of the sample survived their tests, and %d held a test past the bound',
  map { $ended{$_} || 0 } qw(survived hung);
tallied_ok( 'own', @own_kills );
Gate::checked( 'mutants of the tool in the sample', scalar @chosen,      at_least => 50 );
Gate::checked( 'kills of the tool that ran again',  scalar @own_kills,   at_least => 30 );
Gate::checked( 'mutators with a kill of the tool',  scalar keys %killed, at_least => 12 );

done_testing;
