use strict;
use warnings;
use Test::More;
use Cwd ();
use lib 't/shim/lib';
use ShimHarness qw(project write_file run_bare run_command);

# The experiments observe the interpreter itself, so their helper keeps the modules of the environment out of a probe.
# A test that needs a tool of the platform goes through the helper too, which fails where a job requires the tool.

my $root    = project();
my $harness = Cwd::abs_path('t/shim/lib');

write_file( "$root/environment.pl", <<'PERL' );
print join q{,}, map { defined $ENV{$_} ? $ENV{$_} : 'none' } qw(PERL5OPT PERL5LIB KEPT ADDED);
print {*STDERR} "a diagnostic\n";
exit 3;
PERL
{
    local $ENV{PERL5OPT} = '-MNo::Such::Module';
    local $ENV{PERL5LIB} = "$root/outer";
    local $ENV{KEPT}     = 'kept';
    my $bare = run_bare( root => $root, env => { ADDED => 'added' }, args => ['environment.pl'] );
    is $bare->{stdout}, 'none,none,kept,added', 'a probe gets the environment without the modules that it names';
    is $bare->{stderr}, "a diagnostic\n",       'the standard error of a probe is kept';
    is $bare->{status}, 3,                      'the exit status of a probe is kept';
    is $bare->{signal}, 0,                      'a probe that exits ended by no signal';

    my $cleared = run_bare( root => $root, clear => 1, env => { ADDED => 'added' }, args => ['environment.pl'] );
    is $cleared->{stdout}, 'none,none,none,added', 'a probe with a cleared environment gets the named variables alone';

    my $named = run_bare( root => $root, env => { PERL5OPT => '-Mstrict' }, args => ['environment.pl'] );
    is $named->{stdout}, '-Mstrict,none,kept,none', 'a probe gets the modules that the case itself names';

    my $removed = run_bare( root => $root, env => { KEPT => undef }, args => ['environment.pl'] );
    is $removed->{stdout}, 'none,none,none,none',
      'an undefined value removes a variable from the environment of a probe';

    # A user may preset the layers of every handle, which would change what a probe of the interpreter reads.
    write_file( "$root/settings.pl",
        "print join q{,}, map { defined \$ENV{\$_} ? \$ENV{\$_} : 'none' } qw(PERL_UNICODE PERLIO PERLLIB PERL5DB);\n"
    );
    local $ENV{PERL_UNICODE} = 'SD';
    local $ENV{PERLIO}       = ':crlf';
    local $ENV{PERLLIB}      = "$root/outer";
    local $ENV{PERL5DB}      = 'sub DB::DB {}';
    is run_bare( root => $root, args => ['settings.pl'] )->{stdout}, 'none,none,none,none',
      'a probe gets no setting of the interpreter from the environment';
}

write_file( "$root/signal.pl", "kill 'KILL', \$\$;\nsleep 5;\n" );
is run_bare( root => $root, args => ['signal.pl'] )->{signal}, 9, 'the signal that ended a probe is kept';

mkdir "$root/elsewhere" or die "mkdir: $!";
write_file( "$root/where.pl", "use Cwd ();\nprint Cwd::getcwd();\n" );
is run_command( root => $root, command => [ $^X, 'where.pl' ] )->{stdout}, $root,
  'a command runs in the directory of the project';
is run_command( root => $root, cwd => "$root/elsewhere", command => [ $^X, "$root/where.pl" ] )->{stdout},
  "$root/elsewhere", 'or in the directory that the case names';
my $missing = run_command( root => $root, command => ["$root/no-such-command"] );
is $missing->{status}, 127, 'a command that cannot start ends with the status of a command that was not found';
like $missing->{stderr}, qr/\Aexec \Q$root\E\/no-such-command: \S[^\n]*\n\z/,
  'and its standard error names the command and the reason in one line';

write_file( "$root/need.pl", <<'PERL' );
use strict;
use warnings;
use Test::More;
use ShimHarness qw(need);
need( $ARGV[0], $ARGV[1], 'the platform has no such tool' );
ok 1, 'the test ran';
done_testing;
PERL

sub needing {
    my ( $required, $name, $present ) = @_;
    return run_bare(
        root => $root,
        env  => { TEST_MUTATION_REQUIRE => $required },
        args => [ "-I$harness", 'need.pl', $name, $present ],
    );
}

like needing( q{}, 'toolchain', 1 )->{stdout}, qr/^ok 1 - the test ran$/m, 'a test with its tool runs';
like needing( 'toolchain', 'toolchain', 1 )->{stdout}, qr/^ok 1 - the test ran$/m,
  'a test with a tool that the job requires runs';

my $absent = needing( 'git,class', 'toolchain', 0 );
like $absent->{stdout}, qr/\A1[.][.]0 # skip\S* the platform has no such tool$/mi,
  'a test without its tool leaves the run and states the reason';
is $absent->{status}, 0, 'and the run goes on';

my $refused = needing( 'git, toolchain', 'toolchain', 0 );
isnt $refused->{status}, 0, 'the helper rejects a missing tool that the job requires';
like $refused->{stderr}, qr/^TEST_MUTATION_REQUIRE lists toolchain, and the platform has no such tool$/m,
  'and the message names the capability and the reason';
unlike $refused->{stdout}, qr/^ok 1/m, 'and the test does not run';
isnt needing( ' toolchain ', 'toolchain', 0 )->{status}, 0,
  'spaces around the name of a required capability change nothing';

my $misspelt = needing( q{}, 'toolchian', 1 );
isnt $misspelt->{status}, 0, 'the helper rejects a capability that it does not list';
like $misspelt->{stderr}, qr/^no capability is named toolchian$/m, 'and the message names it';

done_testing;
