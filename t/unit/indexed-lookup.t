use v5.36;
use Test2::V0;
use lib 't/e2e/lib', 't/contract/lib';
use Fixture qw(copy_of write_file);
use World;
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Store::History;

my $root = copy_of('equivalent');
write_file( "$root/lib/Other.pm", 'package Other; sub inc { return $_[0] + 1 } 1;' );
my $config = Test::Mutation::Settings::of_call( { root => $root, jobs => 1 } );
my $result = Test::Mutation::Runner::run( $config, sub { } );
Test::Mutation::Store::History::record( $config, $result, 1 );
write_file( "$root/mutation-report/mutation.json",
    Test::Mutation::Report::Json::render( $result, low => 60, high => 80 ) );
my ($entry) = grep { $_->{status} eq 'Survived' } $result->entries->@*;
my $id = $entry->{mutant}->id;
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
done_testing;
