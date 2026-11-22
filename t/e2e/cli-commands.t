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

sub identifier ($description) {
    my ($id) = permutl( $root, 'list' )->{stdout} =~ /^([0-9a-f]{12})  \S+  \S+  \Q$description\E$/m;
    return $id;
}

subtest 'show prints a mutant as a patch' => sub {
    my $id  = identifier('replaced > with >=');
    my $run = permutl( $root, 'show', $id );
    is $run->{exit}, 0, 'exit status' or diag $run->{stderr};
    is [ split /\n/, $run->{stdout} ],
      [
        "$id  lib/Calc.pm:12:15  comparison  replaced > with >=",
        '--- lib/Calc.pm',
        '+++ lib/Calc.pm',
        '@@ -10,5 +10,5 @@',
        ' sub is_positive {',
        '     my ($n) = @_;',
        '-    return $n > 0 ? 1 : 0;',
        '+    return $n >= 0 ? 1 : 0;',
        ' }',
        q{ },
      ],
      'the heading and a unified diff with two lines of context';
};

subtest 'show prints a mutant that removes lines' => sub {
    my $run = permutl( $root, 'show', identifier('removed the body of add') );
    is [ grep { /\A[-+@]/ } split /\n/, $run->{stdout} ],
      [
        '--- lib/Calc.pm',
        '+++ lib/Calc.pm',
        '@@ -4,6 +4,6 @@',
        '-    my ( $x, $y ) = @_;',
        '-    return $x + $y;',
        '+',
        '+'
      ],
      'the removed lines and the blank lines that keep the line numbers';
};

subtest 'show accepts a unique prefix and refuses an unknown or ambiguous identifier' => sub {
    my $id = identifier('replaced + with -');
    is permutl( $root, 'show', substr $id, 0, 6 )->{exit}, 0, 'a unique prefix';
    my $unknown = permutl( $root, 'show', 'zzzzzz' );
    is $unknown->{exit},   2,                                                'an unknown identifier';
    is $unknown->{stderr}, "permutl: no mutant has the identifier zzzzzz\n", 'the message';
    my $missing = permutl( $root, 'show' );
    is $missing->{exit},   2,                                           'no identifier';
    is $missing->{stderr}, "permutl: show needs a mutant identifier\n", 'the message';
};

subtest 'exec runs a command with one mutant active' => sub {
    my $detected = permutl( $root, 'exec', identifier('replaced + with -'), '--', $^X, '-Ilib', 't/add.t' );
    isnt $detected->{exit}, 0, 'the test fails with the mutant';
    like $detected->{stdout}, qr/^not ok 1 - adds$/m, 'the output of the command passes through';

    my ($survivor) =
      permutl( $root, 'list' )->{stdout} =~ /^([0-9a-f]{12})  lib\/Calc\.pm:12:\d+  comparison  replaced > with >=$/m;
    my $survived = permutl( $root, 'exec', $survivor, '--', $^X, '-Ilib', 't/sign.t' );
    is $survived->{exit}, 0, 'the test passes with a mutant it does not detect';

    is permutl( $root, 'exec', identifier('replaced + with -'), '--', $^X, '-e', 'exit 7' )->{exit}, 7,
      'the exit status of the command is returned';
    ok !glob("$root/.permutl/run-*"), 'the work directory is removed';
};

subtest 'exec refuses a missing identifier or command' => sub {
    my $no_command = permutl( $root, 'exec', identifier('replaced + with -') );
    is $no_command->{exit},   2,                                                         'no command';
    is $no_command->{stderr}, "permutl: exec needs a mutant identifier and a command\n", 'the message';
    is permutl( $root, 'exec', 'zzzzzz', '--', $^X, '-e', '1' )->{exit}, 2,              'an unknown identifier';
};

subtest '--shard splits the mutants into disjoint parts' => sub {
    my $ids = sub (@arguments) {
        return [ map { /\A([0-9a-f]{12})  / ? $1 : () } split /\n/, permutl( $root, 'list', @arguments )->{stdout} ];
    };
    my @all    = $ids->()->@*;
    my @shards = map { $ids->( '--shard', "$_/3" ) } 1 .. 3;
    is [ sort map { $_->@* } @shards ],   [ sort @all ], 'the parts together hold every mutant once';
    is [ map { scalar $_->@* } @shards ], [ 7, 6, 6 ],   'the parts have even sizes';
    is $ids->( '--shard', '1/1' ),        \@all,         'one part is the whole';

    for my $invalid (qw(0/3 4/3 2 a/b)) {
        my $run = permutl( $root, 'list', '--shard', $invalid );
        is $run->{exit}, 2, "--shard $invalid is a usage error";
    }
};

subtest 'version, help, and stray arguments' => sub {
    my $version = permutl( $root, '--version' );
    is $version->{exit}, 0, '--version succeeds';
    like $version->{stdout}, qr/\Apermutl \d+[.]\d+\n\z/, 'the version line';

    my $help = permutl( $root, '--help' );
    is $help->{exit}, 0, '--help succeeds';
    like $help->{stdout}, qr/^Usage: permutl \[run\] \[options\]$/m, 'the usage line';
    like $help->{stdout}, qr/^\s+permutl exec ID -- COMMAND/m,       'the commands';
    my @undocumented = grep { $help->{stdout} !~ /^\s+--\Q$_\E\b/m }
      qw(jobs min-score format report-dir perl source test profile enable disable coverage timeout-factor timeout-floor
      keep-work mutant since shard no-equivalence cache config);
    is \@undocumented, [], 'every option is described';

    my $stray = permutl( $root, 'run', 'surplus' );
    is $stray->{exit},   2,                                        'a stray argument is a usage error';
    is $stray->{stderr}, "permutl: unexpected argument surplus\n", 'the message';
};

done_testing;
