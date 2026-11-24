use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Fixture qw(copy_of write_file);
use Gate;
use Test::Mutation::Settings;
use Test::Mutation::Interrupted;
use Test::Mutation::Pool;
use Test::Mutation::Runner;
use Test::Mutation::Status;
use Test::Mutation::Verdict;

# S10, the reasons: every reason that a status of the catalog may carry, and the cases of this file that make the run give it.
# A run gives the reasons of the runner, and the verdict gives the ones that a run reaches only by chance.
# A reason that no case gives yet is an open finding that names the part of the engine that will give it.

my %given;

# The pairs of a status and a reason that the entries give.
sub given_by (@entries) {
    return map { "$_->{status} $_->{reason}" } grep { defined $_->{reason} } @entries;
}

sub gave (@entries) {
    $given{$_} = 1 for given_by(@entries);
    return;
}

sub pairs () {
    my @pairs;
    for my $status ( Test::Mutation::Status::rows()->@* ) {
        push @pairs, map { $status->name . " $_" } $status->reasons->@*;
    }
    return \@pairs;
}

sub ungiven ( $pairs, $given ) {
    return grep { !$given->{$_} } $pairs->@*;
}

sub project (%files) {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/$_", $files{$_} ) for sort keys %files;
    return $root;
}

# A run of a project in this process, which gives the reasons of its mutants.
# The answer maps each source to the pairs that its mutants give, so a case names the source of each reason.
sub measured ( $root, %settings ) {
    my $config  = Test::Mutation::Settings::of_call( { root => $root, jobs => 2, %settings } );
    my @entries = Test::Mutation::Runner::run( $config, sub (@) { return } )->entries->@*;
    gave(@entries);
    my %by_path;
    for my $entry (@entries) {
        $by_path{ $entry->{mutant}->path }{$_} = 1 for given_by($entry);
    }
    return { map { $_ => [ sort keys $by_path{$_}->%* ] } keys %by_path };
}

# The pairs of one status among the pairs of a source.
sub of_status ( $given, $path, $status ) {
    return [ grep { /\A\Q$status\E / } ( $given->{$path} || [] )->@* ];
}

sub outcome (%fields) {
    return {
        test        => 't/a.t',
        result      => 'pass',
        served      => 1,
        load_failed => 0,
        bypassed    => 0,
        syntax      => undef,
        %fields
    };
}

sub decided (@outcomes) {
    my $state = Test::Mutation::Verdict::start();
    $state = Test::Mutation::Verdict::step( $state, $_ ) for @outcomes;
    my $concluded = Test::Mutation::Verdict::conclude($state);
    gave($concluded);
    return [ given_by($concluded) ];
}

subtest 'the gate rejects a reason that no case gives' => sub {
    my @pairs = ( 'Timeout time-limit', 'Pending interrupted' );
    is [ ungiven( \@pairs, { 'Timeout time-limit' => 1 } ) ], ['Pending interrupted'], 'a reason without a case';
    is [ ungiven( \@pairs, { map { $_ => 1 } @pairs } ) ],    [],                      'every reason with a case';
    is [ given_by( { status => 'Killed', reason => undef }, { status => 'Timeout', reason => 'time-limit' } ) ],
      ['Timeout time-limit'], 'a status without a reason gives none';
};

my $module = "package Small;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n"
  . "sub size { return \$_[0] > 5 ? 'big' : 'small' } ## no mutate\nsub idle { return \$_[0] * 2 }\n1;\n";
my $test = "use Test::More tests => 2;\nuse Small;\nis Small::next_one(2), 3, 'the next one';\n"
  . "is Small::size(9), 'big', 'a size';\n";

# A suppressed line, a line that no test reaches, and two mutants that compile to the code of the original and of each other.
is measured( project( 'lib/Small.pm' => $module, 't/small.t' => $test ) ),
  { 'lib/Small.pm' => [ 'Ignored suppressed', 'NoCoverage unreached' ] }, 'a suppressed line and a line without a test';
is of_status( measured( copy_of('equivalent') ), 'lib/Fold.pm', 'Ignored' ),
  [ 'Ignored same-code-as-mutant', 'Ignored same-code-as-original' ], 'the code of the original and of a mutant';

# A test that waits for its time limit when the mutant is wrong, and one that waits before it loads the mutant.
my $stuck = "use Test::More tests => 1;\nuse Small;\nmy \$next = Small::next_one(2);\n"
  . "sleep 30 if \$next != 3;\nis \$next, 3, 'the next one';\n";
is of_status(
    measured( project( 'lib/Small.pm' => $module, 't/stuck.t' => $stuck ), timeout_factor => 4, timeout_floor => 0.5 ),
    'lib/Small.pm',
    'Timeout'
  ),
  ['Timeout time-limit'], 'a time limit after the load';

# A test that prints without end when the mutant is wrong, which the pool ends at the output limit of the run.
my $flood = "use Small;\nmy \$next = Small::next_one(2);\ndefined \$next or die \"no value\\n\";\n"
  . "if ( \$next != 3 ) { print STDERR 'x' x 65_536 while 1 }\nprint \"1..1\\nok 1\\n\";\n";
is of_status( measured( project( 'lib/Small.pm' => $module, 't/flood.t' => $flood ) ), 'lib/Small.pm', 'Timeout' ),
  ['Timeout output-limit'], 'an output limit after the load';
my $slow = "use Test::More tests => 1;\nBEGIN { select undef, undef, undef, 0.6 }\n"
  . "use Small;\nis Small::next_one(2), 3, 'the next one';\n";
is of_status(
    measured( project( 'lib/Small.pm' => $module, 't/slow.t' => $slow ), timeout_factor => 0.1, timeout_floor => 0.1 ),
    'lib/Small.pm',
    'NoVerdict'
  ),
  ['NoVerdict unstable-test'], 'a time limit before the load';

# A mutant that dies while it compiles, a source that fails a syntax check of its own, and a test that loads around the hook.
my $guarded = "package Guarded;\nuse strict;\nuse warnings;\nBEGIN { die \"no room\\n\" if 2 < 1 }\n"
  . "sub size { return \$_[0] > 5 ? 'big' : 'small' }\n1;\n";
my $bound = "package Bound;\nuse strict;\nuse warnings;\nBEGIN { die \"no application\\n\" if !\$main::APPLICATION }\n"
  . "sub size { return 10 > 5 ? 'big' : 'small' }\n1;\n";
my $compiled = measured(
    project(
        'lib/Guarded.pm' => $guarded,
        'lib/Bound.pm'   => $bound,
        'lib/Small.pm'   => $module,
        't/guarded.t'    => "use Test::More tests => 1;\nuse Guarded;\nis Guarded::size(9), 'big', 'a size';\n",
        't/bound.t'      => "use Test::More tests => 1;\nBEGIN { \$main::APPLICATION = 1 }\nuse Bound;\n"
          . "is Bound::size(), 'big', 'a size';\n",

        # A child of the test loads the mutated file again from its path when the mutant changes the result.
        't/around.t' => "use Test::More tests => 1;\nuse Cwd ();\nuse Small;\nmy \$next = Small::next_one(2);\n"
          . "system \$^X, '-e', 'require shift', Cwd::getcwd() . '/lib/Small.pm' if \$next != 3;\n"
          . "is \$next, 3, 'the next one';\n",
    )
);
is of_status( $compiled, 'lib/Guarded.pm', 'CompileError' ), ['CompileError compile-phase'], 'a mutant that dies';
is of_status( $compiled, 'lib/Bound.pm',   'CompileError' ), ['CompileError standalone'], 'a source that fails alone';
is of_status( $compiled, 'lib/Small.pm',   'NoVerdict' ),    ['NoVerdict loaded-around-hook'], 'a load around the hook';

# A mutant that leaves a file in the project, which breaks another test from then on.
my $plain = $module =~ s/ ## no mutate//r;
my $writer =
    "use Test::More tests => 1;\nuse Small;\nmy \$next = Small::next_one(2);\n"
  . "if ( \$next != 3 ) { open my \$out, '>', 'left-behind.txt' or die \$!; close \$out }\n"
  . "is \$next, 3, 'the next one';\n";
my $reader = "use Test::More tests => 2;\nuse Small;\nok !-e 'left-behind.txt', 'no file is in the way';\n"
  . "is Small::size(9), 'big', 'a size';\n";
is of_status(
    measured(
        project( 'lib/Small.pm' => $plain, 't/reader.t' => $reader, 't/writer.t' => $writer ),
        jobs     => 1,
        in_place => 1
    ),
    'lib/Small.pm',
    'NoVerdict'
  ),
  ['NoVerdict project-changed'], 'a test that a mutant breaks for good';

# A signal that ends the measurement after the unmodified run and before any mutant.
{
    my $calls = 0;
    my $pool  = \&Test::Mutation::Pool::run;
    no warnings 'redefine';
    local *Test::Mutation::Pool::run = sub (@arguments) {
        die Test::Mutation::Interrupted->new( signal => 'TERM' ) if ++$calls > 1;
        return $pool->(@arguments);
    };
    is measured( project( 'lib/Small.pm' => $module, 't/small.t' => $test ) ),
      { 'lib/Small.pm' => [ 'Ignored suppressed', 'Pending interrupted' ] }, 'a signal before the mutants';
}

# A test that reached the line in the unmodified run and never loaded the mutant.
is decided( outcome( served => 0 ) ), ['NoCoverage not-loaded'], 'a test that never loads the mutant';

my $pairs   = pairs();
my @ungiven = ungiven( $pairs, \%given );
Gate::findings( 'contract-reason-reasons', [ map { "no case gives the reason $_" } @ungiven ] );
Gate::checked( 'reasons of the catalog',    scalar $pairs->@*,     at_least => 20 );
Gate::checked( 'reasons that a case gives', $pairs->@* - @ungiven, at_least => 13 );

done_testing;
