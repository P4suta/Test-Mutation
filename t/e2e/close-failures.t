use v5.36;
use Test2::V0;
use Cwd ();

# A close that fails means lost data or an unread error, so the run and the command check every close.
# The override below closes the handle and then reports a failure to the subroutine that the pattern names.
our $failing;

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::close = sub : prototype(;*) (@handle) {
        my $closed = @handle ? CORE::close( $handle[0] ) : CORE::close();
        my $caller = ( caller 1 )[3] || 'main';
        return $closed if !defined $failing || $caller !~ $failing;
        $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
}

use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture);
use Test::Mutation::CLI;
use Test::Mutation::Config;
use Test::Mutation::Git;
use Test::Mutation::Runner;

sub failing_in ( $pattern, $code ) {
    local $failing = $pattern;
    return $code->();
}

my $root = copy_of('calc');

like dies {
    failing_in( qr/::Runner::_slurp\z/,
        sub { Test::Mutation::Runner::analyze( Test::Mutation::Config->new( root => $root ) ) } )
},
  qr/\Acannot close \Q$root\E\/lib\/Calc[.]pm: /,
  'a source file that does not close stops the analysis';
like dies {
    failing_in( qr/::Runner::_spew\z/, sub { run_fixture($root) } )
}, qr/\Acannot close \S+: /, 'a work file that does not close stops the run';
like dies {
    failing_in( qr/::Runner::_taint_switch\z/, sub { run_fixture($root) } )
}, qr/\Acannot close t\/\w+[.]t: /, 'a test file that does not close stops the run';

sub command (@arguments) {
    my $here = Cwd::getcwd();
    my ( $output, $errors ) = ( q{}, q{} );
    chdir $root or die "chdir: $!";
    my $status = do {
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$output or die "stdout: $!";
        open STDERR, '>', \$errors or die "stderr: $!";
        Test::Mutation::CLI::main(@arguments);
    };
    chdir $here or die "chdir: $!";
    return ( $status, $errors, $output );
}

for my $part ( 1, 2 ) {
    my ($status) = command( 'run', '--shard', "$part/2", '--report-dir', "part$part", '--format', 'json', '--jobs', 2 );
    is $status, 0, "part $part runs";
}
my @reports = ( 'part1/mutation.json', 'part2/mutation.json' );

my ( $status, $errors ) = failing_in( qr/::CLI::_read_report\z/, sub { command( 'merge', @reports ) } );
is [ $status, $errors =~ s/: [^:\n]+\n\z//r ], [ 2, 'mutation: cannot close part1/mutation.json' ],
  'a report that does not close is a usage error';

( $status, $errors ) =
  failing_in( qr/::CLI::_report\z/, sub { command( 'merge', @reports, '--format', 'json', '--report-dir', 'whole' ) } );
is [ $status, $errors =~ s/: [^:\n]+\n\z//r ], [ 4, 'mutation: cannot close whole/mutation.json' ],
  'a report file that does not close after the write fails the command';

{
    local $ENV{GITHUB_STEP_SUMMARY} = "$root/summary.md";
    ( $status, $errors ) =
      failing_in( qr/::CLI::_report_to_github\z/, sub { command( 'merge', @reports, '--format', 'github' ) } );
    is [ $status, $errors =~ s/: [^:\n]+\n\z//r ], [ 4, "mutation: cannot close $root/summary.md" ],
      'a job summary that does not close fails the command';
}

SKIP: {
    skip 'the case needs the git command', 1 if !length qx{git --version 2>/dev/null};
    is dies {
        failing_in( qr/::Git::_git\z/, sub { Test::Mutation::Git::changed( $root, 'HEAD' ) } )
    }, "git diff failed\n", 'a git answer that does not close fails without a reason';
}

done_testing;
