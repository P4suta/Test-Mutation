use v5.36;
use Test2::V0;
use JSON::PP ();
use Module::CPANfile;
use Permutl::CLI;

# META.json repeats facts that live elsewhere, so the gate fails when the copies drift apart.

open my $handle, '<:raw', 'META.json' or die "read META.json: $!";
my $meta = JSON::PP->new->utf8->decode( do { local $/ = undef; readline $handle } );
close $handle or die "close META.json: $!";

my $declared = Module::CPANfile->load('cpanfile')->prereq_specs;

is $meta->{name},                       'Permutl',                      'the distribution name';
is $meta->{version},                    Permutl::CLI->VERSION,          'the version of the modules';
is $meta->{license},                    [ 'mit', 'apache_2_0' ],        'the licenses of the repository';
is $meta->{prereqs}{runtime}{requires}, $declared->{runtime}{requires}, 'runtime requirements match cpanfile';
is $meta->{prereqs}{test}{requires},    $declared->{test}{requires},    'test requirements match cpanfile';
is $meta->{prereqs}{configure}{requires}, { 'Module::Build::Tiny' => '0.039' }, 'the build tool';

open my $build, '<', 'Build.PL' or die "read Build.PL: $!";
like do { local $/ = undef; readline $build }, qr/^use Module::Build::Tiny 0[.]039;$/m,
  'Build.PL loads the declared build tool';
close $build or die "close Build.PL: $!";

done_testing;
