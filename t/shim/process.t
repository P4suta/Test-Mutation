use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file write_spec run_perl records lib_dir);

my $original = "package Foo::Bar;\nsub answer { return 42 }\n1;\n";
my $mutant   = "package Foo::Bar;\nsub answer { return 41 }\n1;\n";

sub prepare {
    my ($script) = @_;
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm", $original );
    write_file( "$root/mutant.pm",      $mutant );
    write_file( "$root/script.pl",      $script );
    write_file( "$root/child.pl",       "use Foo::Bar;\nprint 'child=', Foo::Bar::answer(), \"\\n\";\n" );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Foo/Bar.pm", "$root/mutant.pm" ] ] );
    return $root;
}

subtest 'a child perl started through PERL5OPT gets the mutant' => sub {
    my $root = prepare("system( \$^X, '-Ilib', 'child.pl' ) == 0 or die 'child failed';\n");
    my $run  = run_perl(
        root => $root,
        env  => {
            TEST_MUTATION_SPEC   => "$root/spec",
            TEST_MUTATION_RECORD => "$root/records",
            PERL5OPT             => '-MTest::Mutation::Shim',
            PERL5LIB             => lib_dir(),
        },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    is $run->{status},                                             0,            'exit status' or diag $run->{stderr};
    is $run->{stdout},                                             "child=41\n", 'the child ran the mutant';
    is scalar( grep { $_->[0] eq 'served' } @{ records($root) } ), 1,            'the child recorded the serve';
};

subtest 'a forked child that loads the target records the serve' => sub {
    my $root = prepare(<<'PERL');
my $pid = fork;
if ( !$pid ) {
    require Foo::Bar;
    print 'forked=', Foo::Bar::answer(), "\n";
    exit 0;
}
waitpid $pid, 0;
PERL
    my $run = run_perl(
        root => $root,
        env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    is $run->{status},                                             0,             'exit status' or diag $run->{stderr};
    is $run->{stdout},                                             "forked=41\n", 'the forked child ran the mutant';
    is scalar( grep { $_->[0] eq 'served' } @{ records($root) } ), 1,             'one serve is recorded';
};

subtest 'taint mode works with explicit switches' => sub {
    my $root = prepare("use Foo::Bar;\nprint 'taint=', \${^TAINT}, ' answer=', Foo::Bar::answer(), \"\\n\";\n");
    my $run  = run_perl(
        root => $root,
        env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" },
        args => [ '-T', '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    is $run->{status}, 0,                     'exit status' or diag $run->{stderr};
    is $run->{stdout}, "taint=1 answer=41\n", 'the mutant runs under taint mode';
    is_deeply [ map { $_->[0] } @{ records($root) } ], [ 'served', 'compiled', 'end' ],
      'the record is written under taint mode';
};

subtest 'loading the shim twice activates it once' => sub {
    my $root = prepare("use Foo::Bar;\nprint 'hooks=', scalar( grep { ref } \@INC ) - \$ENV{OUTER_HOOKS}, \"\\n\";\n");
    my $run  = run_perl(
        root => $root,
        env  => {
            TEST_MUTATION_SPEC   => "$root/spec",
            TEST_MUTATION_RECORD => "$root/records",
            PERL5OPT             => '-MTest::Mutation::Shim',
            PERL5LIB             => lib_dir(),
        },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    is $run->{stdout}, "hooks=1\n", 'one hook is installed';
};

subtest 'without a spec the shim stays inactive' => sub {
    my $root = prepare(
        "use Foo::Bar;\nprint 'hooks=', scalar( grep { ref } \@INC ) - \$ENV{OUTER_HOOKS}, ' answer=', Foo::Bar::answer(), \"\\n\";\n"
    );
    my $run = run_perl( root => $root, args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ] );
    is $run->{stdout}, "hooks=0 answer=42\n", 'no hook and the original behavior';
};

done_testing;
