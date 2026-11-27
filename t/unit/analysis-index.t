use v5.36;
use Test2::V0;
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
done_testing;
