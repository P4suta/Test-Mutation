use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(write_file);
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $project = File::Temp::tempdir( CLEANUP => 1 );
my @paths;
for my $number ( 0 .. 64 ) {
    my $package = sprintf 'Sum%02d', $number;
    my $path    = "lib/$package.pm";
    push @paths, $path;
    write_file( "$project/$path", "package $package;\n" . 'sub sum { return $_[0] + $_[1] }' . "\n1;\n" );
}
my $config = Test::Mutation::Settings::of_call( { root => $project } );

subtest 'every source in a full batch and its remainder enters the catalog once' => sub {
    my $selection = Test::Mutation::Select::resolve( config => $config );
    is [ map { $_->path } $selection->mutants->@* ], [ map { ($_) x 3 } @paths ],
      'the three changes to each sum stay in file order across the batch boundary';
};

done_testing;
