use v5.36;
use Test2::V0;
use Cwd ();
use lib 't/e2e/lib';
use Fixture qw(copy_of);
use Test::Mutation::CLI;
use Test::Mutation::Error;
use Test::Mutation::Interrupted;
use Test::Mutation::Runner;

# The command ends every error with one line, also an error that no code of the command raises on purpose.

my $root = copy_of('calc');

sub command ( $failure, @arguments ) {
    my $here = Cwd::getcwd();
    my ( $output, $errors ) = ( q{}, q{} );
    chdir $root or die "chdir: $!";
    my $status = do {
        no warnings 'redefine';
        local *Test::Mutation::Runner::analyze = $failure;
        local *STDOUT;    ## no critic (Variables::RequireInitializationForLocalVars)
        local *STDERR;    ## no critic (Variables::RequireInitializationForLocalVars)
        open STDOUT, '>', \$output or die "stdout: $!";
        open STDERR, '>', \$errors or die "stderr: $!";
        Test::Mutation::CLI::main(@arguments);
    };
    chdir $here or die "chdir: $!";
    return [ $status, $errors, $output ];
}

is command( sub { die 'the analysis broke' }, 'list' ), [ 6, "mutation: internal error: the analysis broke\n", q{} ],
  'an error with the place of its source loses the place';
is command( sub { die "first line\nsecond line\n" }, 'list' ), [ 6, "mutation: internal error: first line\n", q{} ],
  'an error of several lines keeps the first';
is command( sub { die { code => 7 } }, 'list' ), [ 6, "mutation: internal error: HASH\n", q{} ],
  'an error that is no text and no object ends the command too';
is command( sub { Test::Mutation::Error::raise( 'file-unreadable', path => 'lib/Calc.pm', reason => 'gone' ) },
    'list' ),
  [ 5, "mutation: cannot read lib/Calc.pm: gone\n", q{} ], 'an error of the environment gives its message and status 5';
is command( sub { die Test::Mutation::Interrupted->new( signal => 'HUP' ) }, 'list' ),
  [ 129, "mutation: interrupted by SIGHUP\n", q{} ], 'an interruption gives the status of its signal';

# A signal that arrives where the command offers no check still ends the command with its status.
my $quiet = { sources => {}, mutants => [], problems => [], left_out => {}, rejected => [] };
is command( sub { kill 'TERM', $$; return { $quiet->%*, inventory => { mutants => 0, digest => 'a' x 64 } } }, 'list' ),
  [ 143, "mutation: interrupted by SIGTERM\n", "0 mutants\n" ],
  'a signal during the last step of a command ends it with the status of the signal';
is command( sub { return { $quiet->%*, inventory => { mutants => 0, digest => 'a' x 64 } } }, 'list' ),
  [ 0, q{}, "0 mutants\n" ], 'and the same command without a signal succeeds';

done_testing;
