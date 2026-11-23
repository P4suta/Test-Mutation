use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Cwd        ();
use File::Temp ();
use Fixture    qw(copy_of mutation mutation_from tree_digest write_file);
use Test::Mutation::Mutator::Catalog;

my $root = copy_of('calc');

subtest 'list prints every mutant without running a test' => sub {
    my $before = tree_digest($root);
    my $run    = mutation( $root, 'list' );
    is $run->{exit}, 0, 'exit status' or diag $run->{stderr};
    my @lines = split /\n/, $run->{stdout};
    is scalar(@lines), 20, 'one line for each mutant and a count';
    like $lines[0], qr/\A[0-9a-f]{12}  lib\/Calc\.pm:5:10  sub-body  removed the body of add\z/,
      'identifier, place, mutator, description';
    is $lines[-1],         '19 mutants', 'the count';
    is tree_digest($root), $before,      'nothing is written';
};

subtest '--root runs the command as if it had started in the named directory' => sub {
    my $elsewhere = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $listed    = mutation( $elsewhere, '--root', $root, 'list' );
    is $listed->{stdout}, mutation( $root, 'list' )->{stdout}, 'list names the mutants of the project';
    is mutation( $elsewhere, 'list', '-C', $root )->{stdout}, $listed->{stdout}, 'the option may follow the command';

    my $inside = mutation( $elsewhere, '--root', $root, 'exec', identifier('replaced + with -'),
        '--', $^X, '-MCwd', '-e', 'print Cwd::getcwd()' );
    is $inside->{stdout}, $root, 'exec starts its command in the project';

    my $missing = mutation( $elsewhere, '--root', "$elsewhere/none", 'list' );
    is [ $missing->@{qw(exit stdout)} ], [ 2, q{} ], 'a directory that does not exist is a usage error';
    like $missing->{stderr}, qr/\Amutation: cannot enter \Q$elsewhere\E\/none: [^\n]+\n\z/, 'with one line';
    is [ glob "$elsewhere/*" ], [], 'the directory of the caller gets no file';

    my $library = Cwd::abs_path('lib');
    local $ENV{PERL5LIB} = join q{:}, grep { $_ ne $library } split /:/, defined $ENV{PERL5LIB} ? $ENV{PERL5LIB} : q{};
    my $relative = mutation_from( 'lib', Cwd::getcwd(), '--root', $root, '--jobs', 2, '--format', 'terminal' );
    is $relative->{exit}, 0, 'a relative library directory of the caller still serves the run'
      or diag $relative->{stderr};
    like $relative->{stdout}, qr/^Score: 68\.4%/m, 'and the run measures the project';
};

subtest 'list marks suppressed mutants and honors the mutator options' => sub {
    my $copy = copy_of('calc');
    write_file( "$copy/lib/Quiet.pm", "package Quiet;\nsub sum { return \$_[0] + \$_[1] }    ## no mutate\n1;\n" );
    my $run = mutation( $copy, 'list', '--disable', 'sub-body', '--source', 'lib/Quiet.pm' );
    like $run->{stdout}, qr/^[0-9a-f]{12}  lib\/Quiet\.pm:2:\d+  arithmetic  replaced \+ with -  \(suppressed\)$/m,
      'a suppressed mutant';
    unlike $run->{stdout}, qr/sub-body/, 'a disabled mutator is absent';
};

sub identifier ($description) {
    my ($id) = mutation( $root, 'list' )->{stdout} =~ /^([0-9a-f]{12})  \S+  \S+  \Q$description\E$/m;
    return $id;
}

subtest 'show prints a mutant as a patch' => sub {
    my $id  = identifier('replaced > with >=');
    my $run = mutation( $root, 'show', $id );
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
    my $run = mutation( $root, 'show', identifier('removed the body of add') );
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
    is mutation( $root, 'show', substr $id, 0, 6 )->{exit}, 0, 'a unique prefix';
    my $unknown = mutation( $root, 'show', 'zzzzzz' );
    is $unknown->{exit},   2,                                                 'an unknown identifier';
    is $unknown->{stderr}, "mutation: no mutant has the identifier zzzzzz\n", 'the message';
    my $missing = mutation( $root, 'show' );
    is $missing->{exit},   2,                                            'no identifier';
    is $missing->{stderr}, "mutation: show needs a mutant identifier\n", 'the message';
};

subtest 'exec runs a command with one mutant active' => sub {
    my $detected = mutation( $root, 'exec', identifier('replaced + with -'), '--', $^X, '-Ilib', 't/add.t' );
    isnt $detected->{exit}, 0, 'the test fails with the mutant';
    like $detected->{stdout}, qr/^not ok 1 - adds$/m, 'the output of the command passes through';

    my ($survivor) =
      mutation( $root, 'list' )->{stdout} =~ /^([0-9a-f]{12})  lib\/Calc\.pm:12:\d+  comparison  replaced > with >=$/m;
    my $survived = mutation( $root, 'exec', $survivor, '--', $^X, '-Ilib', 't/sign.t' );
    is $survived->{exit}, 0, 'the test passes with a mutant it does not detect';

    is mutation( $root, 'exec', identifier('replaced + with -'), '--', $^X, '-e', 'exit 7' )->{exit}, 7,
      'the exit status of the command is returned';
    is mutation( $root, 'exec', identifier('replaced + with -'), '--', "$root/no-such-command" )->{exit}, 127,
      'a command that cannot start gives the status of a shell';
    is mutation( $root, 'exec', identifier('replaced + with -'), '--', $^X, '-e', 'kill TERM => $$; sleep 5' )->{exit},
      143, 'a command that a signal ended gives 128 plus the signal';
    ok !-e "$root/.permutl", 'the work directory is removed';
};

subtest 'exec refuses a missing identifier or command' => sub {
    my $no_command = mutation( $root, 'exec', identifier('replaced + with -') );
    is $no_command->{exit},   2,                                                          'no command';
    is $no_command->{stderr}, "mutation: exec needs a mutant identifier and a command\n", 'the message';
    is mutation( $root, 'exec', 'zzzzzz', '--', $^X, '-e', '1' )->{exit}, 2,              'an unknown identifier';
};

subtest '--shard splits the mutants into disjoint parts' => sub {
    my $ids = sub (@arguments) {
        return [ map { /\A([0-9a-f]{12})  / ? $1 : () } split /\n/, mutation( $root, 'list', @arguments )->{stdout} ];
    };
    my @all    = $ids->()->@*;
    my @shards = map { $ids->( '--shard', "$_/3" ) } 1 .. 3;
    is [ sort map { $_->@* } @shards ],   [ sort @all ], 'the parts together hold every mutant once';
    is [ map { scalar $_->@* } @shards ], [ 7, 6, 6 ],   'the parts have even sizes';
    is $ids->( '--shard', '1/1' ),        \@all,         'one part is the whole';

    for my $invalid (qw(0/3 4/3 2 a/b)) {
        my $run = mutation( $root, 'list', '--shard', $invalid );
        is $run->{exit}, 2, "--shard $invalid is a usage error";
    }
};

subtest 'mutators names every mutator with its profile and its description' => sub {
    my $run = mutation( $root, 'mutators' );
    is $run->{exit}, 0, 'exit status' or diag $run->{stderr};
    my @lines = split /\n/, $run->{stdout};
    is scalar(@lines), scalar( Test::Mutation::Mutator::Catalog::mutators()->@* ), 'one line for each mutator';
    like $run->{stdout}, qr/^arithmetic +default +Replaces an arithmetic operator with its counterpart$/m,
      'a mutator of the default profile';
    like $run->{stdout}, qr/^regex-anchor +extended +Removes an anchor from a pattern$/m,
      'a mutator of the extended profile';
    my %columns = map { /\A(\S+ +)(\S+ +)/ ? ( length($1) . q{ } . length $2 => 1 ) : ( none => 1 ) } @lines;
    is [ keys %columns ], ['21 10'], 'the columns line up two spaces after the longest name and profile';
};

subtest 'version, help, and stray arguments' => sub {
    my $version = mutation( $root, '--version' );
    is $version->{exit}, 0, '--version succeeds';
    like $version->{stdout}, qr/\Amutation \d+[.]\d+\n\z/, 'the version line';

    my $help = mutation( $root, '--help' );
    is $help->{exit}, 0, '--help succeeds';
    like $help->{stdout}, qr/^Usage: mutation \[run\] \[options\]$/m, 'the usage line';
    like $help->{stdout}, qr/^\s+mutation exec ID -- COMMAND/m,       'the commands';
    like $help->{stdout}, qr/^\s+mutation merge FILE/m,               'the merge command';
    like $help->{stdout}, qr/^\s+mutation mutators$/m,                'the mutators command';
    my @undocumented = grep { $help->{stdout} !~ /^\s+--\Q$_\E\b/m }
      qw(root jobs min-score format report-dir perl source test profile enable disable coverage timeout-factor timeout-floor
      in-place keep-work mutant since shard no-equivalence cache config);
    is \@undocumented, [], 'every option is described';

    my $stray = mutation( $root, 'run', 'surplus' );
    is $stray->{exit},   2,                                         'a stray argument is a usage error';
    is $stray->{stderr}, "mutation: unexpected argument surplus\n", 'the message';

    my $listed = mutation( $root, 'mutators', 'surplus' );
    is [ $listed->@{qw(exit stdout stderr)} ], [ 2, q{}, "mutation: unexpected argument surplus\n" ],
      'mutators refuses a stray argument and prints no list';
};

done_testing;
