use v5.36;
use Test2::V0;
use lib 't/e2e/lib', 't/contract/lib';
use Fixture qw(copy_of);
use World;
use Test::Mutation;
use Test::Mutation::Store;

sub traced ($operation) {
    my %counts  = ( writes => 0, writers => 0, totals => 0, history => 0 );
    my $connect = Test::Mutation::Store->can('_connect');
    no warnings 'redefine';
    local *Test::Mutation::Store::_connect = sub ($path) {    ## no critic (Variables::ProtectPrivateVars)
        my $db     = $connect->($path);
        my $writes = 0;
        $db->sqlite_trace(
            sub ($sql) {
                if ( $sql =~ /INSERT OR REPLACE INTO verdict/ ) {
                    $counts{writers}++ unless $writes++;
                    $counts{writes}++;
                }
                $counts{totals}++ if $writes && $sql =~ /SELECT count\(\*\) FROM verdict/i;
                $counts{history}++ if $sql =~ /SELECT/i && $sql =~ /\bobservation\b/;
            }
        );
        return $db;
    };
    my $result = $operation->();
    return ( $result, \%counts );
}

my $root = copy_of('calc');
my ( $cold, $work ) = traced( sub { Test::Mutation::run( root => $root, jobs => 1 ) } );
ok $work->{writes} > 1, 'the measurement publishes multiple reusable verdicts';
is $work->{writers}, 1, 'all checkpoints in one measurement use one writer';
is $work->{totals},  0, 'a committed checkpoint does not count the entire verdict table';
my ( $listed, $queries ) = traced( sub { World::observe( ['list'], cwd => $root ) } );
is $listed->{exit},     0, 'the measured catalog can be listed';
is $queries->{history}, 1, 'listing the catalog reads its dated observations in one query';
done_testing;
