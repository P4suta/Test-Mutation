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

subtest 'a large source leaves the next index lookup available for small sources' => sub {
    my $large = "$project/$paths[0]";
    write_file( $large, Test::Mutation::Source::read_bytes($large) . q{#} . ( 'x' x ( 1024 * 1024 ) ) . "\n" );
    my @lookups;
    my $open = Test::Mutation::Store->can('read_database');
    no warnings 'redefine';
    local *Test::Mutation::Store::read_database = sub (@arguments) {
        my $db = $open->(@arguments);
        $db->sqlite_trace(
            sub ($sql) {
                my ($identities) = $sql =~ /\bFROM analysis WHERE identity IN \(([^()]*)\)/i;
                push @lookups, scalar split /,/, $identities if defined $identities;
            }
        );
        return $db;
    };
    Test::Mutation::Select::resolve( config => $config );
    is \@lookups, [ 1, 64 ], 'the large file occupies one lookup and the remaining files share the next';
};

done_testing;
