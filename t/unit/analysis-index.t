use v5.36;
use Test2::V0;
use DBD::SQLite::Constants qw(SQLITE_LIMIT_EXPR_DEPTH SQLITE_LIMIT_VARIABLE_NUMBER);
use File::Temp             ();
use lib 't/e2e/lib';
use Fixture qw(copy_of write_file);
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $root = copy_of('calc');
write_file( "$root/lib/Other.pm", 'package Other; sub plus { return $_[0] + 1 } 1;' );
my $config  = sub (%given) { Test::Mutation::Settings::of_call( { root => $root, %given } ) };
my $all     = Test::Mutation::Select::resolve( config => $config->() );
my $id      = $all->mutants->[0]->id;
my $analyze = Test::Mutation::Syntax::PPI->can('analyze');
my @parsed;
{
    no warnings 'redefine';
    local *Test::Mutation::Syntax::PPI::analyze = sub ($source) {
        push @parsed, $source->path;
        return $analyze->($source);
    };
    my $named = Test::Mutation::Select::resolve( config => $config->( mutant => [$id] ) );
    is [ map { $_->id } $named->mutants->@* ], [$id],           'the index resolves the selected mutant';
    is [ sort keys $named->sources->%* ],      ['lib/Calc.pm'], 'a named result exposes the source of the selected ID';
    is \@parsed,                               [],              'an indexed named measurement parses no source';
    write_file( "$root/lib/Other.pm", 'package Other; sub plus { return $_[0] - 1 } 1;' );
    my $listed = Test::Mutation::Select::resolve( config => $config->() );
    is \@parsed, ['lib/Other.pm'], 'a changed source reparses only that file';
    @parsed = ();
    Test::Mutation::Select::resolve( config => $config->( disable => ['arithmetic'] ) );
    is \@parsed, [qw(lib/Calc.pm lib/Other.pm)], 'a changed operator selection invalidates the cached analysis';
    @parsed = ();
    Test::Mutation::Select::resolve( config => $config->( cache => 0 ) );
    is \@parsed, [qw(lib/Calc.pm lib/Other.pm)], 'disabling the cache forces fresh analysis';
}
subtest 'a missing historical identifier names its previous file' => sub {
    my @refused;
    no warnings 'redefine';
    local *Test::Mutation::Error::raise = sub ( $id, %fields ) {
        @refused = ( $id, \%fields );
        die "selection refused\n";
    };
    my $prefix = '123456789abc';
    ok dies {
        Test::Mutation::Select::resolve(
            config           => $config->( mutant => [$prefix] ),
            historical_paths => { $prefix => 'lib/Previous.pm' }
        );
    }, 'a stale selection stops before testing';
    is \@refused, [ 'mutant-history-stale', { identifier => $prefix, path => 'lib/Previous.pm' } ],
      'the diagnostic carries the identifier and the file to remeasure';
};
subtest 'thousands of named mutants fit within SQLite query limits' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    my $methods = join "\n", map { sprintf 'sub sum%03d { return $_[0] + $_[1] }', $_ } 1 .. 96;
    for my $number ( 1 .. 7 ) {
        write_file( "$project/lib/Arithmetic$number.pm", "package Arithmetic$number;\n$methods\n1;\n" );
    }
    my $settings = Test::Mutation::Settings::of_call( { root => $project } );
    my @ids      = map { $_->id } Test::Mutation::Select::resolve( config => $settings )->mutants->@*;
    is scalar @ids, 2016, 'each of the 672 sums has three mutants';
    my $candidate_queries = 0;
    my $database          = Test::Mutation::Store->can('database');
    no warnings 'redefine';
    local *Test::Mutation::Store::database = sub (@arguments) {
        my $db = $database->(@arguments);
        $db->sqlite_limit( SQLITE_LIMIT_VARIABLE_NUMBER, 999 );
        $db->sqlite_limit( SQLITE_LIMIT_EXPR_DEPTH,      100 );
        $db->sqlite_trace( sub ($sql) { ++$candidate_queries if $sql =~ /\bFROM candidate\b/i } );
        return $db;
    };
    my $selected =
      Test::Mutation::Select::resolve( config => $settings, identifiers => [ reverse @ids, @ids[ 0, 1 ] ] );
    is [ map { $_->id } $selected->mutants->@* ], \@ids,
      'complete identifiers retain inventory order without duplicates';
    cmp_ok $candidate_queries, '<=', 5, 'two thousand complete identifiers use at most five candidate queries';
    my @prefixes = map { substr $_, 0, 11 } @ids;
    $selected = Test::Mutation::Select::resolve( config => $settings, identifiers => [ reverse @prefixes, $ids[0] ] );
    is [ map { $_->id } $selected->mutants->@* ], \@ids, 'short prefixes and an overlapping complete identifier agree';
    $selected = Test::Mutation::Select::resolve( config => $settings, identifiers => [] );
    is $selected->mutants, [], 'an explicitly empty list selects zero mutants';
    my $db       = Test::Mutation::Store::database( Test::Mutation::Store::path( $settings, 0 ) );
    my $analyses = $db->selectcol_arrayref('SELECT identity FROM analysis');
    $candidate_queries = 0;
    my $invalid = Test::Mutation::Store::Analysis::read_files( $db, $analyses, [ q{}, 'G', 'bad?/', 'ff*' ] );
    is [ sort keys %$invalid ], [ sort @$analyses ], 'cached file facts survive a request with no valid prefixes';
    ok !grep( { $_->{mutants}->@* } values %$invalid ), 'an invalid prefix never expands to every mutant';
    is $candidate_queries, 0, 'a request with no valid prefixes skips candidate queries';
    my $leading_zero = Test::Mutation::Store::Analysis::read_files( $db, $analyses, ['0'] );
    is [
        sort map {
            map { $_->id }
              $_->{mutants}->@*
        } values %$leading_zero
      ],
      [ sort grep { /\A0/ } @ids ],
      'the hexadecimal zero remains a valid prefix';
    my @missing = map { "missing-$_" } 1 .. 1200;
    my $found   = Test::Mutation::Store::Analysis::read_files( $db, [ @missing, @$analyses ], [ $ids[0] ] );
    is [ sort keys %$found ], [ sort @$analyses ], 'a large file catalog returns facts only for current analyses';
    is [
        map {
            map { $_->id } $_->{mutants}->@*
        } values %$found
      ],
      [ $ids[0] ],
      'a large file catalog still resolves the requested mutant';
};
done_testing;
