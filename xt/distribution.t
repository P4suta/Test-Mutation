use v5.36;
use Test2::V0;
use Archive::Tar           ();
use IO::Uncompress::Gunzip ();
use Cwd                    ();
use File::Path             ();
use File::Temp             ();
use JSON::PP               ();
use Module::CPANfile;
use Permutl;

# The gate builds the distribution in a scratch copy and checks what an installation would receive.

my $root    = Cwd::getcwd();
my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

open my $list, q{-|}, 'git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z' or die "git: $!";
my @files = split /\0/, do { local $/ = undef; readline $list };
close $list or die 'git ls-files failed';

for my $file (@files) {
    next if !-f "$root/$file";
    my ($directory) = "$scratch/$file" =~ m{\A(.*)/};
    File::Path::make_path($directory);
    open my $in,  '<:raw', "$root/$file"    or die "read $file: $!";
    open my $out, '>:raw', "$scratch/$file" or die "write $file: $!";
    print {$out} do { local $/ = undef; readline $in }
      or die "copy $file: $!";
    close $out or die "close $file: $!";
}

sub in_scratch (@command) {
    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        chdir $scratch or die "chdir: $!";
        open STDOUT, '>',  "$scratch/build.log" or die "stdout: $!";
        open STDERR, '>&', \*STDOUT             or die "stderr: $!";
        exec @command or die "exec: $!";
    }
    waitpid $pid, 0;
    return $? == 0;
}

sub build_log {
    open my $log, '<', "$scratch/build.log" or return 'no build log';
    local $/ = undef;
    return scalar readline $log;
}

ok in_scratch( $^X, 'Makefile.PL' ), 'Makefile.PL runs'             or diag build_log();
ok in_scratch('make'),               'make builds the distribution' or diag build_log();

ok -x "$scratch/blib/script/permutl",                                              'the command is built';
ok -f "$scratch/blib/lib/Permutl.pm",                                              'the main module is built';
ok -f "$scratch/blib/lib/Permutl/Report/resources/mutation-test-elements.js",      'the bundled viewer is built';
ok -f "$scratch/blib/lib/Permutl/Report/resources/mutation-test-elements.LICENSE", 'with its license text';

open my $handle, '<:raw', "$scratch/MYMETA.json" or die "read MYMETA.json: $!";
my $meta = JSON::PP->new->utf8->decode( do { local $/ = undef; readline $handle } );
close $handle or die "close MYMETA.json: $!";

my $declared = Module::CPANfile->load("$root/cpanfile")->prereq_specs;
is $meta->{name},                       'Permutl',                      'the distribution name';
is $meta->{version},                    Permutl->VERSION,               'the version of the main module';
is $meta->{license},                    [ 'mit', 'apache_2_0' ],        'the licenses of the repository';
is $meta->{prereqs}{runtime}{requires}, $declared->{runtime}{requires}, 'runtime requirements match cpanfile';
is $meta->{prereqs}{test}{requires},    $declared->{test}{requires},    'test requirements match cpanfile';

my $version = qx{$^X -I$scratch/blib/lib $scratch/blib/script/permutl --version};
is $version, 'permutl ' . Permutl->VERSION . "\n", 'the built command runs';

ok in_scratch( 'make', 'test' ), 'make test passes' or diag build_log();
my ($test_files) = build_log() =~ /^Files=(\d+), Tests=\d+/m;
ok defined $test_files && $test_files >= 25, 'and runs the unit, assumption, and shim tests' or diag build_log();

ok in_scratch( 'make', 'manifest' ), 'make writes the manifest'    or diag build_log();
ok in_scratch( 'make', 'dist' ),     'make packs the distribution' or diag build_log();

my $prefix = 'Permutl-' . Permutl->VERSION;
my %packed = map { $_ => 1 } Archive::Tar->list_archive("$scratch/$prefix.tar.gz");
my @wanted = qw(
  Makefile.PL cpanfile META.json README.md LICENSE-MIT LICENSE-APACHE THIRD_PARTY_NOTICES.md bin/permutl
  lib/Permutl.pm lib/Permutl/Shim.pm lib/Test/Permutl.pm lib/Permutl/Report/resources/mutation-test-elements.js
  t/unit/tap.t t/shim/serve.t t/fixtures/calc/lib/Calc.pm
);
is [ grep { !$packed{"$prefix/$_"} } @wanted ], [], 'the archive holds the sources, the tests, and the notices';
is [ grep { m{\A\Q$prefix\E/(?:local|blib|[.]git|[.]permutl|permutl-report)(?:/|\z)|[.]log\z} } sort keys %packed ], [],
  'and leaves out installed dependencies, build output, and reports';

IO::Uncompress::Gunzip::gunzip( "$scratch/$prefix.tar.gz" => \my $bytes ) or die 'cannot read the archive';
ok $bytes !~ /(?:LIBARCHIVE|SCHILY)[.]xattr/, 'the archive carries no extended attribute of the build machine';
is [ grep { m{/[.]_} } sort keys %packed ], [], 'and no resource fork file';

done_testing;
