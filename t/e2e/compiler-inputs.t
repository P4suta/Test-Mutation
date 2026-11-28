use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(ran run_fixture write_file);
use Test::Mutation::Merge;
use Test::Mutation::Report::Json;
use Test::Mutation::Source;

my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

subtest 'an opaque phase can change a package variable without changing the compiled program' => sub {
    my $root = "$area/global";
    local $ENV{TEST_PROJECT_TABLE} = "$area/global-limit";
    write_file( "$root/lib/Bound.pm", <<'PERL' );
package Bound;
our $LIMIT;
BEGIN {
    my $path = $ENV{TEST_PROJECT_TABLE};
    open my $input, '<', $path or die $!;
    $LIMIT = 0 + <$input>;
    close $input or die $!;
}
sub first { return $_[0] < $LIMIT }
sub second { return $_[0] < $LIMIT }
1;
PERL
    write_file( "$root/t/limit.t",
        "use Test::More tests => 2; use Bound; ok !Bound::first(7); ok !Bound::second(7);\n" );
    my @reports;
    for my $part ( 1, 2 ) {
        write_file( $ENV{TEST_PROJECT_TABLE}, $part == 1 ? "7\n" : "5\n" );
        my $dir = "$area/global-part$part";
        ran(
            0,          $root, 'run', '--shard', "$part/2", '--no-cache', '--jobs', 1,
            '--enable', 'comparison-boundary',
            ( map { ( '--disable', $_ ) } qw(@removal comparison-negation arithmetic logical) ),
            '--format', 'json', '--report-dir', $dir
        );
        my $file        = "$dir/mutation.json";
        my $part_result = Test::Mutation::Report::Json::parse( Test::Mutation::Source::read_bytes($file) );
        is [ map { $_->{status} } $part_result->entries->@* ], [ $part == 1 ? 'Killed' : 'Survived' ],
          'the test observes the value assigned during compilation';
        push @reports, $file;
    }
    my $merge = ran( 2, $root, 'merge', @reports, '--format', 'json', '--report-dir', "$area/global-joined" );
    like $merge->{stderr}, qr/measurement inputs are missing/, 'the compiled program cannot identify the phase input';
};

subtest 'loading a module can read external data at file scope' => sub {
    my $root = "$area/file-scope";
    local $ENV{PERL5LIB}           = join q{:}, "$area/threshold", grep { defined } $ENV{PERL5LIB};
    local $ENV{TEST_PROJECT_TABLE} = "$area/table";
    write_file( "$area/threshold/Threshold.pm", <<'PERL' );
package Threshold;
my $path = $ENV{TEST_PROJECT_TABLE};
open my $input, '<', $path or die $!;
my $limit = 0 + <$input>;
close $input or die $!;
sub limit { return $limit }
1;
PERL
    write_file( "$root/lib/Bound.pm", <<'PERL' );
package Bound;
use Threshold ();
sub first { return $_[0] < Threshold::limit() }
sub second { return $_[0] < Threshold::limit() }
1;
PERL
    write_file( "$root/t/check.t",
        "use Test::More tests => 2; use Bound; ok !Bound::first(7); ok !Bound::second(7);\n" );
    my $part = sub ($number) {
        my ($result) = run_fixture(
            $root,
            jobs        => 1,
            cache       => 1,
            shard       => "$number/2",
            equivalence => 0,
            enable      => ['comparison-boundary'],
            disable     => [qw(@removal comparison-negation arithmetic logical)]
        );
        return { name => "$number", result => $result };
    };
    write_file( $ENV{TEST_PROJECT_TABLE}, "7\n" );
    my $first = $part->(1);
    is $part->(2)->{result}->entries->[0]{status}, 'Killed', 'the initial value distinguishes the boundary';
    write_file( $ENV{TEST_PROJECT_TABLE}, "5\n" );
    my $different = $part->(2);
    is [ $different->{result}->entries->[0]{status}, $different->{result}->cache_mismatch ], [ 'Survived', 0 ],
      'a cached observation checks the input before sampling';
    like dies { Test::Mutation::Merge::merge( [ $first, $different ] ) }, qr/measurement inputs (?:are missing|differ)/,
      'a changed file-scope value makes the measurements incompatible';
};

done_testing;
