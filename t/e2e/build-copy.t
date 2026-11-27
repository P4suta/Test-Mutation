use v5.36;
use Test2::V0;
use Config     qw(%Config);
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(ran run_fixture tree_digest write_file);
use Test::Mutation::Settings;
use Test::Mutation::Source;

my $module = "package Built;\nsub value { return \$_[0] + 2 }\nsub unused { return \$_[0] * 2 }\n1;\n";
my $test   = "use Test::More tests => 1;\nuse lib 'blib/lib';\nuse Built;\nis Built::value(3), 5;\n";

sub project () {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/lib/Built.pm", $module );
    write_file( "$root/t/built.t",    $test );
    return $root;
}

sub addition ($report) {
    my ($entry) = grep { $_->{mutant}->description eq 'replaced + with -' } $report->entries->@*;
    return $entry || {};
}

subtest 'a generator rebuilds the selected source inside the private tree' => sub {
    my $root = project();
    write_file( "$root/.proverc",    "-b\n" );
    write_file( "$root/Makefile.PL", <<'CONFIGURE' );
use strict;
use warnings;
open my $output, '>', 'Makefile' or die $!;
print {$output} qq{all:\n\t"$^X" generate.pl\n};
close $output or die $!;
CONFIGURE
    write_file( "$root/generate.pl", <<'GENERATOR' );
use strict;
use warnings;
use File::Path qw(make_path);
make_path('blib/lib');
open my $in, '<:raw', 'lib/Built.pm' or die $!;
open my $out, '>:raw', 'blib/lib/Built.pm' or die $!;
print {$out} "# generated\n", <$in>;
close $out or die $!;
GENERATOR
    my $before = tree_digest($root);
    my ($report) = run_fixture( $root, cache => 0, jobs => 1, equivalence => 0 );
    is $report->baseline_failures,  [],       'the original compiles after configuration and build';
    is addition($report)->{status}, 'Killed', 'the test loaded the regenerated addition';
    my $exec = ran( 0, $root, 'exec', addition($report)->{mutant}->id,
        '--', $^X, '-Iblib/lib', '-MBuilt', '-e', 'print Built::value(8)' );
    is $exec->{stdout}, '6', 'the user command loads the regenerated module from its own private build';
    my ($unused) = grep { $_->{mutant}->description eq 'replaced * with /' } $report->entries->@*;
    is +( $unused || {} )->{status}, 'NoCoverage', 'the generator prefix still maps to source lines';
    is tree_digest($root),           $before, 'configure, build, and measurement leave the working directory intact';
};

subtest 'a generated copy that does not update has a reason' => sub {
    my $root = project();
    write_file( "$root/blib/lib/Built.pm", "# generated elsewhere\n$module" );
    my ($report) = run_fixture( $root, jobs => 1, equivalence => 0 );
    is $report->baseline_failures, [], 'the existing generated module passes';
    my $entry = addition($report);
    is [ $entry->@{qw(status reason)} ], [ 'NoVerdict', 'build-copy-not-updated' ],
      'the installed bytes never saw the mutant';
    like $entry->{detail} || q{}, qr{blib/lib/Built[.]pm}, 'the result names the stale product';
    my $exec = ran( 125, $root, 'exec', $entry->{mutant}->id, '--', $^X, '-e', 'print "command started"' );
    is $exec->{stdout}, q{}, 'exec refuses to start the user command when it would load the original';
    like $exec->{stderr}, qr{blib/lib/Built[.]pm.*private build.*lib/Built[.]pm},
      'the diagnostic identifies the unchanged private product and the source the user selected';
};

subtest 'an XS project uses the build libraries and requires a build recipe' => sub {
    my $root = project();
    write_file( "$root/Native.xs", "/* a native source */\n" );
    is Test::Mutation::Settings::of_call( { root => $root } )->lib, [qw(blib/lib blib/arch)],
      'native sources select the build libraries';
    my $run = ran( 2, $root, 'baseline' );
    like $run->{stderr}, qr{Makefile[.]PL.*Build[.]PL.*-C},
      'the diagnostic explains how to run a separately built distribution';
};

subtest 'a private build loads the actual native object' => sub {
    my $root = project();
    write_file( "$root/Makefile.PL", "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Built', VERSION => '0.01');\n" );
    write_file( "$root/lib/Built.pm", <<'MODULE' );
package Built;
our $VERSION = '0.01';
require XSLoader;
XSLoader::load('Built', $VERSION);
sub value { return $_[0] + native_value() }
1;
MODULE
    write_file( "$root/Built.xs", <<'XS' );
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

MODULE = Built PACKAGE = Built
PROTOTYPES: DISABLE

int
native_value()
  CODE:
    RETVAL = 2;
  OUTPUT:
    RETVAL
XS
    write_file( "$root/t/built.t",
        "use Test::More tests => 2;\nuse Built;\nis Built::native_value(), 2;\nis Built::value(3), 5;\n" );
    my $before = tree_digest($root);
    my ($report) = run_fixture( $root, cache => 0, jobs => 1, equivalence => 0 );
    is $report->baseline_failures,  [],       'the compiled XS function runs without a prebuilt shared object';
    is addition($report)->{status}, 'Killed', 'the Perl addition uses the native function in its own job';
    my $stats    = $report->stats;
    my $expected = 2 + $stats->{baseline_tests} + $stats->{verifications} + $stats->{compiles};
    $expected += $_->{tests_run} for $report->entries->@*;
    is $stats->{spawns},   $expected, 'configure and build each start one additional process';
    is tree_digest($root), $before,   'no generated code or object file reaches the checkout';
};

subtest 'a Build.PL project builds when an interpreter option selects blib' => sub {
    my $root = project();
    write_file( "$root/Build.PL", <<'CONFIGURE' );
use strict;
use warnings;
open my $out, '>', 'Build' or die $!;
print {$out} q{use File::Path qw(make_path); use File::Copy qw(copy); make_path('blib/lib'); copy('lib/Built.pm','blib/lib/Built.pm') or die $!;};
close $out or die $!;
CONFIGURE
    my ($report) = run_fixture( $root, jobs => 1, switch => ['-Iblib/lib'], equivalence => 0 );
    is $report->baseline_failures,  [],       'the selected interpreter executes the generated Build program';
    is addition($report)->{status}, 'Killed', 'the built library sees the mutation';
    ok !-e "$root/Build", 'configuration happened in the disposable tree';
};

subtest 'a configuration failure carries its command and output' => sub {
    my $root = project();
    write_file( "$root/.proverc", "-b\n" );
    write_file( "$root/Build.PL", "die qq{missing test build dependency\\n};\n" );
    my $run = ran( 5, $root, 'baseline' );
    like $run->{stderr}, qr{Build[.]PL.*missing test build dependency},
      'the build diagnostic identifies the failed command';
};

subtest 'in-place measurement rejects an older product and leaves both files alone' => sub {
    my $root = project();
    write_file( "$root/.proverc",          "-b\n" );
    write_file( "$root/blib/lib/Built.pm", $module );
    utime 1000, 1000, "$root/blib/lib/Built.pm" or die "utime: $!";
    my $before = tree_digest($root);
    my $run    = ran( 2, $root, 'baseline', '--in-place' );
    like $run->{stderr}, qr{blib/lib/Built[.]pm.*make}, 'the diagnostic identifies the file to rebuild and the command';
    is tree_digest($root), $before, 'nothing in the project changes';
};
subtest 'a newer object for another extension cannot satisfy an in-place build' => sub {
    my $root = project();
    write_file( "$root/Makefile.PL", "# an existing build recipe\n" );
    for my $extension (qw(Built Other)) {
        write_file( "$root/$extension.xs", "/* $extension */\n" );
        my $object = "$root/blib/arch/auto/$extension/$extension.$Config{dlext}";
        write_file( $object, 'native object' );
        utime 2000, 2000, "$root/$extension.xs" or die "utime: $!";
        my $built = $extension eq 'Built' ? 1000 : 3000;
        utime $built, $built, $object or die "utime: $!";
    }
    like ran( 2, $root, 'baseline', '--in-place' )->{stderr}, qr{Built[.]xs.*make},
      'the stale extension names its own source';
};
done_testing;
