use v5.36;
use Test2::V0;
use Encode     ();
use File::Temp ();
use lib 't/contract/lib';
use Samples;
use World;
use Test::Mutation::Report::Live;
use Test::Mutation::Runner;
use Test::Mutation::CLI;
use Test::Mutation::Source;

my $dir  = File::Temp::tempdir( CLEANUP => 1 );
my $word = "unknown-\x{2603}";
for my $has_output ( 0, 1 ) {
    my ( $exit, $out_flush, $err_flush, @warnings );
    my $errors = "$dir/diagnostic-$has_output";
    {
        local *STDOUT;    ## no critic (Variables::RequireInitializationForLocalVars)
        local *STDERR;    ## no critic (Variables::RequireInitializationForLocalVars)
        if ($has_output) {
            open STDOUT, '>:raw', "$dir/report" or die "open report: $!";
            STDOUT->autoflush(0);
        }
        open STDERR, '>:raw', $errors or die "open diagnostic: $!";
        STDERR->autoflush(0);
        local $SIG{__WARN__} = sub ($message) { push @warnings, $message };
        $exit      = Test::Mutation::CLI::main("--$word");
        $out_flush = STDOUT->autoflush if $has_output;
        $err_flush = STDERR->autoflush;
        close STDERR or die "close diagnostic: $!";
        close STDOUT or die "close report: $!" if $has_output;
    }
    is $exit,      2,  'an unknown option reports a usage error';
    is \@warnings, [], 'terminal detection emits no Perl warning for a closed output';
    is $out_flush, 1,  'an open report stream flushes immediately' if $has_output;
    is $err_flush, 1,  'diagnostics flush immediately even when the report stream is closed';
    my $bytes = Encode::encode( 'UTF-8', $word );
    like Test::Mutation::Source::read_bytes($errors), qr/\Q$bytes\E/,
      'the diagnostic encodes the original spelling in UTF-8';
}

{
    open my $terminal, '+<', '/dev/ptmx' or die "open a pseudo-terminal: $!";
    is Test::Mutation::CLI::_terminal($terminal), 1, 'the CLI recognizes a live terminal descriptor';    ## no critic (Subroutines::ProtectPrivateSubs)
    close $terminal or die "close the pseudo-terminal: $!";
}

for my $case ( [ 0, 0, 0 ], [ 0, 1, 1 ], [ 1, 0, 1 ], [ 1, 1, 1 ] ) {
    my ( $out, $err, $colored ) = @$case;
    my $planned =
      World::observe( ['baseline'], cwd => $dir, out_tty => $out, err_tty => $err, env => {}, run => 'plan' );
    is $planned->{plan}{config}->color, $colored, 'either attached terminal enables automatic color for that stream';
}

subtest 'progress and the score select color for their own streams' => sub {
    my $sample = Samples::result( statuses => ['Killed'] );
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub ( $config, $listener, $options ) {
        $listener->( 'phase', { name => 'baseline' } );
        return $sample;
    };
    for my $case (
        [ 0, 0, [],             {},                  [ 0, 0 ] ],
        [ 0, 1, [],             {},                  [ 0, 1 ] ],
        [ 1, 0, [],             {},                  [ 1, 0 ] ],
        [ 1, 1, [],             { NO_COLOR => q{} }, [ 1, 1 ] ],
        [ 0, 0, ['--color'],    {},                  [ 1, 1 ] ],
        [ 1, 1, ['--no-color'], {},                  [ 0, 0 ] ],
        [ 1, 1, ['--color'],    { NO_COLOR => '1' }, [ 0, 0 ] ],
      )
    {
        my ( $out, $err, $option, $env, $expected ) = @$case;
        my $seen = World::observe(
            [ 'run', '--format', 'terminal', @$option ],
            cwd     => $dir,
            out_tty => $out,
            err_tty => $err,
            env     => $env
        );
        is $seen->{exit}, 0, 'the measurement completed';
        is [ map { /\e\[/ ? 1 : 0 } $seen->@{qw(stdout stderr)} ], $expected,
          "terminal flags $out and $err with @$option select the expected report and progress colors";
    }
};

subtest 'baseline accepts progress color and reports each unmodified failure' => sub {
    my @requests;
    my $failure = { test => 't/sample.t', output => "not ok 1\n", errors => q{} };
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub ( $config, $listener, $options ) {
        push @requests, $options;
        $listener->( 'phase', { name => 'baseline' } );
        return Samples::result( statuses => [], baseline_failures => [$failure] );
    };
    my $seen = World::observe( [ 'baseline', '--color' ], cwd => $dir );
    is $seen->{exit},   3,                    'a failing original stops the baseline command';
    is $seen->{stdout}, "Baseline: 1 test\n", 'the command counts the original tests';
    like $seen->{stderr}, qr/\e\[.*Baseline/s,  'explicit color reaches the progress stream';
    like $seen->{stderr}, qr/^t\/sample[.]t$/m, 'the failing test is named on standard error';
    my $invalid = World::observe( [ 'baseline', '--min-score', 90 ], cwd => $dir );
    is $invalid->{exit}, 2, 'a score threshold cannot apply to the original tests';
    like $invalid->{stderr}, qr/--min-score is no option of baseline/,
      'the diagnostic identifies the inapplicable option';
    is \@requests, [ { baseline_only => 1 } ], 'only the valid command runs the original tests';
};

subtest 'the listener receives each published report after its bytes are written' => sub {
    my @written;
    my $sample = Samples::result( statuses => ['Killed'] );
    no warnings 'redefine';
    local *Test::Mutation::Runner::run            = sub { return $sample };
    local *Test::Mutation::Report::Live::listener = sub {
        return sub ( $event, $data ) {
            push @written, [ $data->{path}, -s "$dir/$data->{path}" ? 1 : 0 ] if $event eq 'report_written';
        };
    };
    my $seen = World::observe( [ 'run', '--format', 'json', '--format', 'html' ], cwd => $dir );
    is $seen->{exit}, 0, 'the command published the reports';
    is \@written, [ [ 'mutation-report/mutation.json', 1 ], [ 'mutation-report/mutation.html', 1 ] ],
      'the listener sees the paths and complete files in publication order';
};

done_testing;
