use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of permutl tree_digest write_file);

my $root = copy_of('calc');

subtest 'list prints every mutant without running a test' => sub {
    my $before = tree_digest($root);
    my $run    = permutl( $root, 'list' );
    is $run->{exit}, 0, 'exit status' or diag $run->{stderr};
    my @lines = split /\n/, $run->{stdout};
    is scalar(@lines), 20, 'one line for each mutant and a count';
    like $lines[0], qr/\A[0-9a-f]{12}  lib\/Calc\.pm:5:10  sub-body  removed the body of add\z/,
      'identifier, place, mutator, description';
    is $lines[-1],         '19 mutants', 'the count';
    is tree_digest($root), $before,      'nothing is written';
};

subtest 'list marks suppressed mutants and honors the mutator options' => sub {
    my $copy = copy_of('calc');
    write_file( "$copy/lib/Quiet.pm", "package Quiet;\nsub sum { return \$_[0] + \$_[1] }    ## no mutate\n1;\n" );
    my $run = permutl( $copy, 'list', '--disable', 'sub-body', '--source', 'lib/Quiet.pm' );
    like $run->{stdout}, qr/^[0-9a-f]{12}  lib\/Quiet\.pm:2:\d+  arithmetic  replaced \+ with -  \(suppressed\)$/m,
      'a suppressed mutant';
    unlike $run->{stdout}, qr/sub-body/, 'a disabled mutator is absent';
};

done_testing;
