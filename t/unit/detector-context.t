use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib', 'xt/lib';
use Fixture qw(run_fixture write_file);
use SelfMeasurement;
use Test::Mutation::Report::Json;
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $body    = <<'BODY';
    my $left = $_[0];
    my $right = $_[1];
    my $sum = $left + $right;
    return $sum;
}
BODY
my $source = "package Example;\nsub sum {\n$body";
my $shift  = "\n\n\n";
my $weak   = "use Test::More tests => 1;\nuse Example;\nis Example::sum(4, 0), 4;\n";
my $strong = "use Test::More tests => 1;\nuse Example;\nis Example::sum(4, 1), 5;\n";

sub project ( $text, $tests, $path = 'lib/Example.pm' ) {
    my $root = File::Temp::tempdir( DIR => $scratch );
    write_file( "$root/$path", "$text\n1;\n" );
    write_file( "$root/$_",    $tests->{$_} ) for sort keys %$tests;
    return $root;
}

sub selection ($root) {
    my $config = Test::Mutation::Settings::of_call( { root => $root, cache => 0 } );
    return Test::Mutation::Select::resolve( config => $config, read_only => 1 );
}

sub additions ($selected) {
    return grep { $_->mutator eq 'arithmetic' } $selected->mutants->@*;
}

sub measured_report ($root) {
    my ($addition) = additions( selection($root) );
    my ($result)   = run_fixture( $root, cache => 0, jobs => 1, mutant => [ $addition->id ] );
    is $result->entries->[0]{status}, 'Killed', 'the earlier test actually detects the selected addition';
    return write_file( "$scratch/" . $addition->id . '.json',
        Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ) );
}

my %tests        = ( 't/a.t' => $weak, 't/z.t' => $strong );
my $previous     = measured_report( project( $source, \%tests ) );
my $current_root = project( "$shift$source", { %tests, 't/a.t' => $strong } );
my $current      = selection($current_root);
my ($addition)   = additions($current);
my $id           = $addition->id;
is SelfMeasurement::detector_hints( $current, $previous ), { $id => 't/z.t' },
  'a moved operator with one matching context can try a previous detector';

my $same_id = measured_report($current_root);
is SelfMeasurement::detector_hints( $current, $same_id, $previous ), { $id => 't/a.t' },
  'an exact ID takes priority over a later report for a different offset';
is SelfMeasurement::detector_hints( $current, $previous, $same_id ), { $id => 't/a.t' },
  'the same exact ID takes priority in either file order';

my $changed   = $source =~ s/\$left \+ \$right/\$left + abs(\$right)/r;
my $following = $source =~ s/return \$sum;/return int \$sum;/r;
my $duplicate = "$source\nsub also {\n$body";
for my $case (
    [ project( "$shift$source", \%tests, 'lib/Renamed.pm' ), 'the expression belongs to another file' ],
    [ project( "$shift$changed",   \%tests ),              'the moved expression changed' ],
    [ project( "$shift$following", \%tests ),              'a line following the moved expression changed' ],
    [ project( "$shift$duplicate", \%tests ),              'the current source has two identical contexts' ],
    [ project( "$shift$source",    { 't/a.t' => $weak } ), 'the earlier detecting test is absent' ],
  )
{
    my $hints;
    my $selected = selection( $case->[0] );
    is warnings { $hints = SelfMeasurement::detector_hints( $selected, $previous ) }, [],
      "ignoring the earlier test is silent when $case->[1]";
    is $hints, {}, $case->[1];
}
my $ambiguous = measured_report( project( "\n$duplicate", \%tests ) );
is SelfMeasurement::detector_hints( $current, $ambiguous ), {},
  'a report of one mutant includes the entire earlier source with both identical contexts';

done_testing;
