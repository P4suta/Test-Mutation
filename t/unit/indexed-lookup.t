use v5.36;
use Test2::V0;
use lib 't/e2e/lib', 't/contract/lib';
use Fixture qw(copy_of write_file);
use World;
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Store::History;

subtest 'planning a path run leaves the catalog to execution' => sub {
    my $project = copy_of('calc');
    my @args    = ( 'run', 'lib/Calc.pm:12', '--format', 'terminal', '--jobs', 1 );
    my $plan    = World::observe( \@args, cwd => $project, run => 'cheap' )->{plan};
    ok !$plan->{refused},        'the plan accepts the file and range';
    ok !-e "$project/.mutation", 'planning creates no cache in the project';
    is World::observe( \@args, cwd => $project )->{exit}, 0, 'the selected range runs';
    ok -f "$project/.mutation/measurement.sqlite", 'execution publishes the file analysis';
    my $parsed  = 0;
    my $analyze = Test::Mutation::Syntax::PPI->can('analyze');
    no warnings 'redefine';
    local *Test::Mutation::Syntax::PPI::analyze = sub (@arguments) { $parsed++; return $analyze->(@arguments) };
    is World::observe( [ 'list', 'lib/Calc.pm:12' ], cwd => $project )->{exit}, 0, 'the measured range can be listed';
    is $parsed, 0, 'the next lookup reads the warm file analysis';
};
my $root = copy_of('equivalent');
write_file( "$root/lib/Other.pm", 'package Other; sub inc { return $_[0] + 1 } 1;' );
my $config = Test::Mutation::Settings::of_call( { root => $root, jobs => 1 } );
my $result = Test::Mutation::Runner::run( $config, sub { } );
Test::Mutation::Store::History::record( $config, $result, 1 );
write_file( "$root/mutation-report/mutation.json",
    Test::Mutation::Report::Json::render( $result, low => 60, high => 80 ) );
my ($entry) = grep { $_->{status} eq 'Survived' } $result->entries->@*;
my $id = $entry->{mutant}->id;
subtest 'a new lookup process loads only the code it uses' => sub {
    my $probe = <<'PERL';
END { print "loaded $_\n" for sort keys %INC }
do './bin/mutation';
die $@ || $!;
PERL
    for my $arguments ( [ 'show', $id ], ['list'] ) {
        open my $child, q{-|}, $^X, '-Ilib', '-e', $probe, '--', '--root', $root, @$arguments
          or die "start the lookup: $!";
        my @output = readline $child;
        ok close($child),                        "$arguments->[0] exits successfully";
        ok scalar( grep { /\Q$id\E/ } @output ), "$arguments->[0] displays the measured mutant";
        my @modules = grep { m{\Aloaded Test/Mutation/(?:Runner|Merge)[.]pm\n\z} } @output;
        is \@modules, [], "$arguments->[0] runs without loading the test runner or merging reports";
    }
};
my ( $parsed, $reports, $restored ) = ( 0, 0, 0 );
my $make    = Test::Mutation::Mutant->can('new');
my $parse   = Test::Mutation::Report::Json->can('parse');
my $analyze = Test::Mutation::Syntax::PPI->can('analyze');
my $decode  = Test::Mutation::Source->can('from_bytes');
my @decoded;
{
    no warnings 'redefine';
    local *Test::Mutation::Source::from_bytes = sub ( $class, %given ) {
        push @decoded, $given{path};
        return $decode->( $class, %given );
    };
    local *Test::Mutation::Mutant::new          = sub (@arguments) { $restored++; return $make->(@arguments) };
    local *Test::Mutation::Report::Json::parse  = sub (@arguments) { $reports++;  return $parse->(@arguments) };
    local *Test::Mutation::Syntax::PPI::analyze = sub (@arguments) { $parsed++;   return $analyze->(@arguments) };
    my $shown = World::observe( [ 'show', substr( $id, 0, 8 ) ], cwd => $root );
    is $shown->{exit}, 0, 'show finds a prefix in the indexed measurement';
    like $shown->{stdout}, qr/^Last result: Survived\nMeasured at: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$/m,
      'show dates the observed status';
    is [ $parsed, $reports, $restored ], [ 0, 0, 1 ], 'show restores one mutant without a parse or full report read';
    is \@decoded,                        [ $entry->{mutant}->path ], 'only the displayed file is decoded for its patch';
    my $listed = World::observe( ['list'], cwd => $root );
    like $listed->{stdout}, qr/^\Q$id\E .* \[Survived\] \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/m,
      'list dates each historical status';
    is [ $parsed, $reports ], [ 0, 0 ], 'list reads the index and skips both parsers';
    my $loads = 0;
    my $load  = Test::Mutation::Store->can('load');
    local *Test::Mutation::Store::load = sub (@arguments) { $loads++; return $load->(@arguments) };
    $restored = 0;
    my $run = World::observe( [ 'run', '--mutant', $id, '--jobs', '1', '--format', 'terminal' ], cwd => $root );
    is $run->{exit}, 0, 'the named mutant is remeasured through the CLI';
    is [ $parsed, $reports, $loads ], [ 0, 0, 0 ],
      'rerunning one mutant skips analysis, full reports, and bulk verdict reads';
    is $restored, 1, 'the rerun restores exactly the requested mutant';
}
subtest 'combined selectors read one completed scope' => sub {
    my $snapshots = 0;
    my $select    = DBI::db->can('selectall_arrayref');
    no warnings 'redefine';
    local *DBI::db::selectall_arrayref = sub ( $connection, $sql, @options ) {
        $snapshots++ if $sql =~ /WITH scope AS/;
        return $select->( $connection, $sql, @options );
    };
    my $rerun = World::observe(
        [ 'run', '--undetected', '--mutant', $id, $entry->{mutant}->path, '--jobs', 1, '--format', 'terminal' ],
        cwd => $root );
    is $rerun->{exit}, 0, 'the combined selection measures the previous survivor';
    is $snapshots,     1, 'all selectors use the same database snapshot even if another measurement finishes';
};
done_testing;
