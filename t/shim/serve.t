use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file write_spec run_perl records lib_dir);

my $original = <<'PERL';
package Foo::Bar;
use strict;
use warnings;

sub add  { return $_[0] + $_[1] }
sub file { return __FILE__ }
sub line { return __LINE__ }
sub from { return call_site() }
sub call_site { return ( caller(0) )[1] }

1;
PERL

( my $mutated = $original ) =~ s/\$_\[0\] \+ \$_\[1\]/\$_[0] - \$_[1]/;

my $script = <<'PERL';
use strict;
use warnings;
use Foo::Bar;
print join( "\n",
    'add=' . Foo::Bar::add( 5, 3 ),
    'file=' . Foo::Bar::file(),
    'line=' . Foo::Bar::line(),
    'from=' . Foo::Bar::from(),
    'inc=' . $INC{'Foo/Bar.pm'},
    'hooks=' . ( scalar( grep { ref } @INC ) - $ENV{OUTER_HOOKS} ),
), "\n";
PERL

sub fields {
    my ($stdout) = @_;
    return { map { split /=/, $_, 2 } split /\n/, $stdout };
}

subtest 'the unmodified run sets the reference values' => sub {
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm", $original );
    write_file( "$root/script.pl",      $script );
    my $run = run_perl( root => $root, args => [ '-Ilib', 'script.pl' ] );
    is $run->{status}, 0, 'exit status' or diag $run->{stderr};
    is_deeply fields( $run->{stdout} ),
      { add => 8, file => 'lib/Foo/Bar.pm', line => 7, from => 'lib/Foo/Bar.pm', inc => 'lib/Foo/Bar.pm', hooks => 0 },
      'natural values';
};

subtest 'the hook serves the mutant under the original identity' => sub {
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm", $original );
    write_file( "$root/mutant.pm",      $mutated );
    write_file( "$root/script.pl",      $script );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Foo/Bar.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    is $run->{status}, 0,   'exit status' or diag $run->{stderr};
    is $run->{stderr}, q{}, 'no warnings';
    is_deeply fields( $run->{stdout} ),
      { add => 2, file => 'lib/Foo/Bar.pm', line => 7, from => 'lib/Foo/Bar.pm', inc => 'lib/Foo/Bar.pm', hooks => 1 },
      'mutated behavior with the original file identity';
    my $records = records($root);
    is_deeply [ map { $_->[0] } @{$records} ], [ 'served', 'compiled', 'end' ],
      'the record has a served line, a compiled line, and an end line';
    is $records->[0][1], "$root/lib/Foo/Bar.pm", 'the record names the served target';
};

subtest 'the shim serves without a record directory' => sub {
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm", $original );
    write_file( "$root/mutant.pm",      $mutated );
    write_file( "$root/script.pl",      $script );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Foo/Bar.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    is $run->{status},                  0,   'exit status';
    is $run->{stderr},                  q{}, 'no warnings';
    is fields( $run->{stdout} )->{add}, 2,   'the mutant is served';
    is_deeply [ glob "$root/*.rec $root/*/*.rec" ], [], 'no record file is written';
};

subtest 'use lib after activation leaves the hook first' => sub {
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm", $original );
    write_file( "$root/mutant.pm",      $mutated );
    write_file( "$root/script.pl",      "use lib 'lib';\nuse lib 'other';\n$script" );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Foo/Bar.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', 'script.pl' ],
    );
    is $run->{status},                  0, 'exit status' or diag $run->{stderr};
    is fields( $run->{stdout} )->{add}, 2, 'the mutant is served';
};

subtest 'a file with the same name elsewhere is left alone' => sub {
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm",   $original );
    write_file( "$root/other/Foo/Bar.pm", $original . "# a different file\n" );
    write_file( "$root/mutant.pm",        $mutated );
    write_file( "$root/script.pl",        $script );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Foo/Bar.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Iother', 'script.pl' ],
    );
    is $run->{status},                  0, 'exit status' or diag $run->{stderr};
    is fields( $run->{stdout} )->{add}, 8, 'the shadowing file runs unmodified';
    is_deeply [ map { $_->[0] } @{ records($root) } ], ['end'], 'nothing is recorded as served';
};

subtest 'an identical copy in another directory is the same target' => sub {
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm",      $original );
    write_file( "$root/blib/lib/Foo/Bar.pm", $original );
    write_file( "$root/mutant.pm",           $mutated );
    write_file( "$root/script.pl",           $script );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Foo/Bar.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Iblib/lib', 'script.pl' ],
    );
    is $run->{status}, 0, 'exit status' or diag $run->{stderr};
    my $fields = fields( $run->{stdout} );
    is $fields->{add},  2,                     'the mutant is served';
    is $fields->{file}, 'blib/lib/Foo/Bar.pm', 'the file identity is the path Perl resolved';
};

subtest 'a file that starts with a byte order mark is served without the mark' => sub {
    my $root = project();
    my $mark = "\xEF\xBB\xBF";
    write_file( "$root/lib/Marked.pm",
        $mark . "package Marked;\nsub value { return 1 }\nsub line { return __LINE__ }\n1;\n" );
    write_file( "$root/mutant.pm",
        $mark . "package Marked;\nsub value { return 2 }\nsub line { return __LINE__ }\n1;\n" );
    write_file( "$root/script.pl", "use Marked;\nprint Marked::value(), Marked::line();\n" );
    is run_perl( root => $root, args => [ '-Ilib', 'script.pl' ] )->{stdout}, '13', 'Perl loads the file with its mark';
    write_spec( "$root/spec", targets => [ [ "$root/lib/Marked.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    is $run->{stdout}, '23', 'the mutant runs, and its lines keep their numbers' or diag $run->{stderr};
};

subtest 'the exit status of the program is preserved' => sub {
    my $root = project();
    write_file( "$root/lib/Foo/Bar.pm", $original );
    write_file( "$root/mutant.pm",      $mutated );
    write_file( "$root/script.pl",      "use Foo::Bar;\nexit 7;\n" );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Foo/Bar.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    is $run->{status}, 7, 'exit status';
};

done_testing;
