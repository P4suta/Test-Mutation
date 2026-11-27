use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
write_file( "$root/lib/Adder.pm", "package Adder;\nsub sum { return \$_[0] + \$_[1] }\n1;\n" );
my $strong = "use Test::More tests => 1;\nuse Adder;\nis Adder::sum(4, 1), 5;\n";
my $weak   = "use Test::More tests => 1;\nuse Adder;\nis Adder::sum(4, 0), 4;\n";
write_file( "$root/t/z.t", $strong );

sub witness ($cache) {
    my ($result)   = run_fixture( $root, cache => $cache, jobs => 1, equivalence => 0 );
    my ($addition) = grep { $_->{mutant}->mutator eq 'arithmetic' } $result->entries->@*;
    return [ $addition->@{qw(status reason by tests_run observations)} ];
}

is witness(1)->[2], 't/z.t', 'the only test detects the change';
write_file( "$root/t/a.t", $weak );
is witness(1), witness(0), 'a new earlier covering test contributes its observation before the detector';
write_file( "$root/t/a.t", $strong );
is witness(1), witness(0), 'an earlier test that now detects the change becomes the reported witness';
unlink "$root/t/a.t" or die $!;
is witness(1), witness(0), 'removing the first witness restores the next detecting test';

done_testing;
