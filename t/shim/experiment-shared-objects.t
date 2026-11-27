use strict;
use warnings;
use Test::More;
use Config;
use lib 't/shim/lib';
use ShimHarness qw(project write_file run_bare);

# Experiment E11: does the list of loaded shared objects name an object that XSLoader loaded?
# The list would let a test process report the compiled code that it ran, next to the Perl files.

my $root = project();
write_file( "$root/script.pl", <<'PERL' );
use strict;
use warnings;
require DynaLoader;
require XSLoader;

my $loads    = 0;
my $original = \&XSLoader::load;
{
    no warnings 'redefine';
    *XSLoader::load = sub { $loads++; goto &{$original} };
}
my $before = @DynaLoader::dl_shared_objects;
require Fcntl;
my @added = @DynaLoader::dl_shared_objects[ $before .. $#DynaLoader::dl_shared_objects ];
my ($path) = @added;
my @modules = do { no warnings 'once'; grep { $_ eq 'Fcntl' } @DynaLoader::dl_modules };
print join( q{ }, "loads=$loads", 'added=' . scalar @added, 'absolute=' . ( $path =~ m{\A/} ? 1 : 0 ),
    'object=' . ( $path =~ m{(auto/.*)\z} ? $1 : $path ), 'exists=' . ( -f $path ? 1 : 0 ), "modules=@modules" ), "\n";
PERL

my $run = run_bare( root => $root, args => ['script.pl'] );
is $run->{stderr}, q{}, 'the probe runs without a warning';
is $run->{stdout}, "loads=1 added=1 absolute=1 object=auto/Fcntl/Fcntl.$Config{dlext} exists=1 modules=Fcntl\n",
  'E11: an object that XSLoader loads joins @DynaLoader::dl_shared_objects under its absolute path';

done_testing;
