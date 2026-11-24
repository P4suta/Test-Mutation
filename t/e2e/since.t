use v5.36;
use Test2::V0;
use lib 't/e2e/lib', 't/lib';
use Capability;
use Fixture qw(copy_of ran write_file);

Capability::need( 'git', length qx{git --version 2>/dev/null}, 'the test needs the git command' );

sub git ( $root, @arguments ) {
    my @command = (
        'git', '-C', $root, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Test',
        '-c',  'user.email=test@example.invalid',
        '-c',  'commit.gpgsign=false', @arguments,
    );
    system(@command) == 0 or die "git @arguments failed";
    return;
}

sub listed ( $root, @arguments ) {
    my $run = ran( 0, $root, 'list', @arguments );
    return [ map { /\A\S+  (\S+)  \S+  (.*)\z/ ? "$1 $2" : () } split /\n/, $run->{stdout} ];
}

my $root = copy_of('calc');
git( $root, 'init',   '-q' );
git( $root, 'add',    '.' );
git( $root, 'commit', '-q', '-m', 'initial' );

subtest 'an unchanged tree has no mutant' => sub {
    is listed( $root, '--since', 'HEAD' ), [], 'no mutant';
};

subtest 'a changed line limits the mutants to the code that holds it' => sub {
    open my $in, '<', "$root/lib/Calc.pm" or die "read: $!";
    my $text = do { local $/ = undef; readline $in };
    close $in                                        or die "close: $!";
    $text =~ s/return \$x \+ \$y;/return \$y + \$x;/ or die 'the fixture changed';
    write_file( "$root/lib/Calc.pm", $text );

    is listed( $root, '--since', 'HEAD' ),
      [
        'lib/Calc.pm:5:10 removed the body of add',
        'lib/Calc.pm:7:12 removed the return value',
        'lib/Calc.pm:7:15 replaced + with -'
      ],
      'the mutants on the changed line and the body that contains it';
    my $run = ran( 0, $root, '--since', 'HEAD', '--jobs', 2, '--format', 'terminal' );
    like $run->{stdout}, qr/^3 mutants: 3 killed$/m, 'run measures the same mutants';
};

subtest 'an untracked source file counts as changed' => sub {
    write_file( "$root/lib/Extra.pm", "package Extra;\nsub one { return 2 - 1 }\n1;\n" );
    my $mutants = listed( $root, '--since', 'HEAD' );
    is scalar( grep { /\Alib\/Extra\.pm:/ } $mutants->@* ), 3, 'every mutant of the new file';
};

subtest 'a revision that git does not know stops the run' => sub {
    my $run = ran( 4, $root, 'list', '--since', 'no-such-revision' );
    like $run->{stderr}, qr/\Amutation: git [^\n]*no-such-revision[^\n]*\n\z/, 'one line that names the revision';
};

subtest 'a change selects the mutants whose lines it touches' => sub {
    my $wide = sub ( $second, $brace ) { "package Wide;\nsub wide {\n    return 1 +\n      2;$second\n}$brace\n1;\n" };
    write_file( "$root/lib/Wide.pm", $wide->( q{}, q{} ) );
    git( $root, 'add', '.' );
    git( $root, 'commit', '-q', '-m', 'second' );
    is listed( $root, '--since', 'HEAD' ), [], 'a committed tree has no mutant';

    write_file( "$root/lib/Wide.pm", $wide->( '    # two', q{} ) );
    is listed( $root, '--since', 'HEAD' ),
      [ 'lib/Wide.pm:2:11 removed the body of wide', 'lib/Wide.pm:3:12 removed the return value' ],
      'the last line of a statement selects the statement and the body around it, in a file after an unchanged one';

    write_file( "$root/lib/Wide.pm", $wide->( q{}, '    # the end' ) );
    is listed( $root, '--since', 'HEAD' ), [], 'the line of the closing brace selects nothing: the body ends before it';
};

done_testing;
