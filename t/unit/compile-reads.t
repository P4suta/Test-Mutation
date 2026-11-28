use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Store::Key;
use Test::Mutation::Syntax::PPI;

sub reads ($source) {
    return scalar Test::Mutation::Syntax::PPI::compile_reads($source);
}

subtest 'scheduled blocks identify the file operands of read-only open' => sub {
    is reads(q{BEGIN { open my $in, '<', $ENV{TABLE} or die $!; close $in }}), [ [ env => 'TABLE' ] ],
      'the target environment supplies one named input';
    is reads(q{UNITCHECK { CORE::open(my $in, '<:raw', '/data/file') }}), [ [ file => '/data/file' ] ],
      'a literal path and a PerlIO layer identify one input';
    is reads(q{BEGIN;}), undef, 'a phase declaration without a body supplies no read evidence';
    is reads(q{sub CHECK { open my $in, '<', 'limits' }}), [ [ file => 'limits' ] ],
      'an explicitly declared phase subroutine runs during compilation';
    is reads(q{BEGIN { unshift @INC, $ENV{LIBRARY}; push @INC, '/opt/lib' }}), [],
      'the compiler already records literal and environment-derived include directories';
    is reads(q{sub load { open my $in, '<', make_path() } # BEGIN }), [],
      'runtime statements do not run in the compiler';
};

subtest 'the compiler cannot identify an indirect read from its operands' => sub {
    is reads(q{BEGIN { open my $in, '<', $ENV{TABLE} . '.other' }}), undef,
      'a path expression is not a single variable';
    is reads(q{BEGIN { read_table() }}), undef, 'a helper may run arbitrary code';
    is reads(q{BEGIN { $ENV{TABLE} = '/other'; open my $in, '<', $ENV{TABLE} }}), undef,
      'the launch environment does not determine a reassigned variable';
    is reads(q{use lib (do { $ENV{TABLE} = 'alternate'; 'lib' }); BEGIN { open my $in, '<', $ENV{TABLE} }}), undef,
      'a parenthesized import argument can change the path before a phase block opens it';
};

subtest 'literal numeric guards have no external compiler inputs' => sub {
    is reads(q{BEGIN { die "broken\n" if 3 - 1 != 2 }}),            [], 'a fixed arithmetic comparison reads no file';
    is reads(q{BEGIN { CORE::die 'broken' unless 2 <= 3 }}),        [], 'a fixed lower bound reads no file';
    is reads(q{BEGIN { die "broken\n" if 3 - read_limit() != 2 }}), undef, 'a call can read an external limit';
    is reads(q{BEGIN { die "broken\n" if -e '/outside' }}),         undef, 'a file test depends on the filesystem';
    is reads(q{BEGIN { die "@{[read_limit()]}" if 1 }}),            undef, 'the error message can execute code';
};

subtest 'an imported module must preserve an environment-derived file operand' => sub {
    my $at_load = sub ($source) { return scalar Test::Mutation::Syntax::PPI::compile_reads( $source, 1 ) };
    is $at_load->(q{package Data; use strict; sub count { return 3 } 1;}), [],
      'declarations and the module return value do not change a binding';
    is $at_load->(q{package Data; $ENV{TABLE} = 'other'; 1;}), undef, 'a file-scope assignment runs on import';
    is $at_load->(q{package Data; apply_settings(); 1;}),      undef, 'a file-scope helper can alter the environment';
    is $at_load->(q{package Data; use strict; sub choose { $ENV{TABLE} = 'other' } choose; 1;}), undef,
      'a bare call after a fixed import runs when the compiler loads the module';
    is $at_load->(q{package Data; sub import { $ENV{TABLE} = 'other' } 1;}), undef, 'an import hook executes on use';
    is $at_load->(q{package Data; use Settings apply_settings(); 1;}), undef, 'an import argument can execute a helper';
};

subtest 'a compiler search path inside the project can resolve to an external library' => sub {
    my $area     = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $project  = "$area/project";
    my $external = "$area/external";
    write_file( "$project/a-local/Local.pm", "package Local; sub floor () { 1 } 1;\n" );
    write_file( "$external/Defaults.pm",     "package Defaults; sub limit () { 3 } 1;\n" );
    symlink $external, "$project/z-defaults" or die "link compiler library: $!";
    local $ENV{TEST_LOCAL_LIBRARY}  = "$project/a-local";
    local $ENV{TEST_LINKED_LIBRARY} = "$project/z-defaults";
    write_file( "$project/lib/Bounds.pm", <<'PERL' );
package Bounds;
use lib $ENV{TEST_LOCAL_LIBRARY}, $ENV{TEST_LINKED_LIBRARY};
use Local ();
use Defaults ();
sub inside { return Local::floor() < Defaults::limit() }
1;
PERL
    write_file( "$project/t/pass.t", "use Test::More tests => 1; pass 'ready';\n" );
    my ($result) = run_fixture( $project, cache => 0, jobs => 1 );
    ok !exists $result->compiler_inputs->{ Test::Mutation::Store::Key::digest("$project/a-local") },
      'the ordinary library is already part of the project';
    is $result->compiler_inputs->{ Test::Mutation::Store::Key::digest($external) },
      Test::Mutation::Store::Key::tree( $external, [] ),
      'the compiler binds the external directory reached by the link';
};

subtest 'standalone compilation records the external file used by an explicit BEGIN subroutine' => sub {
    my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $root = "$area/project";
    local $ENV{PERL5OPT}            = '-Mstrict';
    local $ENV{TEST_COMPILER_LIMIT} = write_file( "$area/limit", "4\n" );
    write_file( "$root/lib/Bound.pm", <<'PERL' );
package Bound;
use warnings 'numeric', 'uninitialized';
sub BEGIN {
    open my $input, '<', $ENV{TEST_COMPILER_LIMIT} or die $!;
    my $limit = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('LIMIT', $limit);
}
sub below { return $_[0] < LIMIT }
1;
PERL
    write_file( "$root/t/check.t", "use Test::More tests => 1; use Bound; ok Bound::below(3);\n" );
    my ($result) = run_fixture( $root, cache => 0, jobs => 1 );
    is $result->baseline_failures, [], 'the target Perl compiles and uses the constant';
    is $result->compiler_inputs->{ Test::Mutation::Store::Key::digest("$area/limit") },
      Test::Mutation::Store::Key::file("$area/limit"), 'the report binds the external bytes used for the constant';
};

subtest 'an import can redirect a relative input before the compiler opens it' => sub {
    my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $root = "$area/project";
    local $ENV{TEST_LIMIT_DIRECTORY} = "$area/data";
    write_file( "$root/limit", "3\n" );
    my $enter = q{$ENV{TEST_PREVIOUS_DIRECTORY} = Cwd::getcwd(); chdir $ENV{TEST_LIMIT_DIRECTORY} or die $!};
    my $leave = q{chdir $ENV{TEST_PREVIOUS_DIRECTORY} or die $!};
    my $read  = <<'PERL';
BEGIN {
    open my $input, '<', 'limit' or die $!;
    my $limit = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('LIMIT', $limit);
}
PERL
    my $source = sub ( $before, $after ) {
        write_file( "$root/lib/Bound.pm", join "\n", 'package Bound;',
            'use Cwd ();', $before, $read, $after, 'sub below { return $_[0] < LIMIT }', "1;\n" );
    };
    $source->( "use warnings do { $enter; 'numeric' };", "use warnings do { $leave; 'numeric' };" );
    write_file( "$root/t/check.t", "use Test::More tests => 1; use Bound; ok !Bound::below(7);\n" );
    my $boundary = sub ($cache) {
        my ($result) = run_fixture(
            $root,
            cache   => $cache,
            jobs    => 1,
            shard   => '1/1',
            enable  => ['comparison-boundary'],
            disable => [qw(@removal arithmetic comparison-negation logical)]
        );
        my ($entry) = grep { $_->{mutant}->mutator eq 'comparison-boundary' } $result->entries->@*;
        return [ $entry->{status}, $result->cache_mismatch, $entry->{compiled_digest} ];
    };
    write_file( "$area/data/limit", "7\n" );
    is $boundary->(1), [ 'Killed', 0, undef ], 'the test distinguishes strict comparison at seven';
    write_file( "$area/data/limit", "5\n" );
    is $boundary->(1), [ 'Survived', 0, undef ], 'the changed limit invalidates the old verdict before cache sampling';
    is $boundary->(0), [ 'Survived', 0, undef ], 'fresh tests agree with the cached run';

    local $ENV{PERL5LIB} = join q{:}, "$area/imports", grep { defined } $ENV{PERL5LIB};
    write_file( "$area/imports/Enter.pm", "package Enter; use Cwd (); $enter; 1;\n" );
    write_file( "$area/imports/Leave.pm", "package Leave; $leave; 1;\n" );
    $source->( 'use Enter ();', 'use Leave ();' );
    is $boundary->(1), [ 'Survived', 0, undef ], 'an imported module can redirect the same literal input';
    write_file( "$area/data/limit", "7\n" );
    is $boundary->(1), [ 'Killed', 0, undef ], 'the previous survival cannot be reused after the data changes';
};

done_testing;
