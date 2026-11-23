use v5.36;
use Test2::V0;
use Cwd ();
use lib 't/e2e/lib';
use Fixture qw(copy_of);
use Test::Mutation::CLI;
use Test::Mutation::Runner;

# The command ends every error with one line, also an error that no code of permutl raises on purpose.

my $root = copy_of('calc');

sub command ( $failure, @arguments ) {
    my $here = Cwd::getcwd();
    my ( $output, $errors ) = ( q{}, q{} );
    chdir $root or die "chdir: $!";
    my $status = do {
        no warnings 'redefine';
        local *Test::Mutation::Runner::analyze = $failure;
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$output or die "stdout: $!";
        open STDERR, '>', \$errors or die "stderr: $!";
        Test::Mutation::CLI::main(@arguments);
    };
    chdir $here or die "chdir: $!";
    return [ $status, $errors, $output ];
}

is command( sub { die 'the analysis broke' }, 'list' ), [ 4, "mutation: the analysis broke\n", q{} ],
  'an error with the place of its source loses the place';
is command( sub { die "first line\nsecond line\n" }, 'list' ), [ 4, "mutation: first line\n", q{} ],
  'an error of several lines keeps the first';
is command( sub { die { code => 7 } }, 'list' )->[0], 4, 'an error that is no text and no object ends the command too';
is command( sub { die Test::Mutation::Interrupted->new( signal => 'HUP' ) }, 'list' ),
  [ 129, "mutation: interrupted by SIGHUP\n", q{} ], 'an interruption gives the status of its signal';

done_testing;
