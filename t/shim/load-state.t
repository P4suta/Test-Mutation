use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file write_spec run_perl records lib_dir);

my $original = "package Foo::Bar;\nsub answer { return 42 }\n1;\n";

sub run_with_mutant {
    my (%case) = @_;
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm", $original );
    write_file( "$root/mutant.pm",      $case{mutant} );
    write_file( "$root/script.pl",      $case{script} );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Foo/Bar.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MPermutl::Shim', '-Ilib', 'script.pl' ],
    );
    return ( $run, [ map { $_->[0] } @{ records($root) } ], $root );
}

subtest 'a mutant that fails to compile is recorded as a load failure' => sub {
    my ( $run, $kinds ) = run_with_mutant(
        mutant => "package Foo::Bar;\nsub answer { return 42 +* }\n1;\n",
        script => "use Foo::Bar;\nprint Foo::Bar::answer();\n",
    );
    isnt $run->{status}, 0, 'the program fails';
    like $run->{stderr}, qr{syntax error at lib/Foo/Bar\.pm line 3}, 'the error names the original file and line';
    is_deeply $kinds, [ 'served', 'loadfail', 'end' ], 'record kinds';
};

subtest 'a mutant that dies while loading is recorded as a load failure' => sub {
    my ( $run, $kinds ) = run_with_mutant(
        mutant => "package Foo::Bar;\ndie 'boom';\n1;\n",
        script => "my \$ok = eval { require Foo::Bar; 1 };\nprint \$ok ? 'loaded' : 'failed';\n",
    );
    is $run->{status}, 0,        'the program survives the trapped failure';
    is $run->{stdout}, 'failed', 'the require failed';
    is_deeply $kinds, [ 'served', 'loadfail', 'end' ], 'record kinds';
};

subtest 'a successful load leaves no failure line' => sub {
    my ( $run, $kinds ) = run_with_mutant(
        mutant => "package Foo::Bar;\nsub answer { return 41 }\n1;\n",
        script => "use Foo::Bar;\nprint Foo::Bar::answer();\n",
    );
    is $run->{stdout}, '41', 'mutated behavior';
    is_deeply $kinds, [ 'served', 'end' ], 'record kinds';
};

subtest 'a target loaded by absolute path is recorded as a bypass' => sub {
    my ( $run, $kinds ) = run_with_mutant(
        mutant => "package Foo::Bar;\nsub answer { return 41 }\n1;\n",
        script => "use Cwd ();\nrequire( Cwd::getcwd() . '/lib/Foo/Bar.pm' );\nprint Foo::Bar::answer();\n",
    );
    is $run->{stdout}, '42', 'the original ran';
    is_deeply $kinds, [ 'bypass', 'end' ], 'record kinds';
};

subtest 'a target that is never required leaves an end line alone' => sub {
    my ( $run, $kinds ) = run_with_mutant(
        mutant => "package Foo::Bar;\nsub answer { return 41 }\n1;\n",
        script => "print 'idle';\n",
    );
    is $run->{stdout}, 'idle', 'the program ran';
    is_deeply $kinds, ['end'], 'record kinds';
};

subtest 'a program that replaces @INC and loads the target bypasses the hook' => sub {
    my ( $run, $kinds ) = run_with_mutant(
        mutant => "package Foo::Bar;\nsub answer { return 41 }\n1;\n",
        script => "BEGIN { \@INC = ('lib') }\nuse Foo::Bar;\nprint Foo::Bar::answer();\n",
    );
    is $run->{stdout}, '42', 'the original ran';
    is_deeply $kinds, [ 'bypass', 'end' ], 'record kinds';
};

done_testing;
