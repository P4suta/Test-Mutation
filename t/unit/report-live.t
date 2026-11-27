use v5.36;
use Test2::V0;
use POSIX  ();
use Symbol ();
use Test::Mutation::Report::Live;
use Test::Mutation::Event;
use Test::Mutation::Signals;

my $elapsed = 0;
my $text    = q{};
open my $errors, '>', \$text or die $!;
my $listen = Test::Mutation::Report::Live::listener( $errors, 0, 0, sub { $elapsed }, '4 processors online' );
$listen->( 'phase', { name => 'baseline' } );
$elapsed = 5;
$listen->( 'tick', {} );
like $text, qr/^Baseline.*5s elapsed/m, 'a quiet baseline reports the time without a completed test';
$listen->( 'analyzed', { files => 1, tests => 2, mutants => 4 } );
$listen->( 'phase',    { name  => 'mutants' } );
$elapsed = 7;
$listen->( 'mutant', { status => 'Ignored' } );
like $text, qr/\[1\/4\] 1 ignored.*7s elapsed.*6s remaining/, 'the estimate uses the time spent measuring mutants';
$elapsed = 10;
$listen->( 'finished', { counts => { Ignored => 1, Pending => 3 }, total => 4 } );
like $text, qr/\[4\/4\] 1 ignored, 3 pending.*10s elapsed/,
  'the last line counts interrupted work from the final result';
unlike $text, qr/\e|\r/, 'a log contains plain lines';
close $errors or die $!;
my @ticks;
my $seconds = 1;
my $value   = Test::Mutation::Event::during(
    sub ( $event, $data ) { push @ticks, [ $event, $data->{time} ] },
    sub {
        for my $instant ( 1, 5, 6, 7, 10, 11 ) {
            $seconds = $instant;
            Test::Mutation::Signals::check();
        }
        return 'finished';
    },
    sub { $seconds }
);
is \@ticks, [ [ tick => 6 ], [ tick => 11 ] ], 'a checkpoint reports each five seconds at the exact boundary';
is $value,  'finished',                        'the watch returns the work result';
$seconds = 60;
Test::Mutation::Signals::check();
is scalar @ticks, 2, 'the completed run has released its listener';

my $invalid = q{};
open my $log, '>', \$invalid or die $!;
my $checking = Test::Mutation::Report::Live::listener( $log, 0, 0, sub { $seconds }, '4 processors online' );
$checking->( 'phase', { name => $_ } ) for qw(resolve analyze release);
$checking->( 'tick',  {} );
is $invalid, q{}, 'a rejected selection leaves room for its single diagnostic';
close $log or die $!;

my $copying = q{};
open my $copy_log, '>', \$copying or die $!;
my $copy = Test::Mutation::Report::Live::listener( $copy_log, 0, 0, sub { $seconds }, '4 processors online' );
$copy->( 'phase',        { name    => 'build' } );
$copy->( 'copy_started', { project => '/project' } );
$seconds += 5;
$copy->( 'tick',          {} );
$copy->( 'copy_finished', { root => '/copy' } );
like $copying, qr/^Build.*^Copy.*^Copy [|] 5s elapsed.*^Build/ms, 'copying has its own phase and returns to the build';
close $copy_log or die $!;

subtest 'a log reports each validated phase, elapsed interval and final count' => sub {
    my $now    = 100.25;
    my $output = q{};
    open my $stream, '>', \$output or die $!;
    my $view = Test::Mutation::Report::Live::listener( $stream, 0, 0, sub { $now }, '2 processors online' );
    my $send = sub ( $elapsed, $event, %data ) {
        $now = 100.25 + $elapsed;
        $view->( $event, \%data );
    };
    $send->( 0,    'unrecognized' );
    $send->( 0,    'finished', total => 0, counts => {} );
    $send->( 0,    'phase',    name  => 'resolve' );
    $send->( 1.25, 'phase',    name  => 'analyze' );
    is $output, q{}, 'the validation phases are held until analysis succeeds';
    $send->( 2.5,   'analyzed',      files => 2, tests => 3, mutants => 20 );
    $send->( 2.75,  'phase',         name  => 'baseline' );
    $send->( 3,     'baseline_test', test  => 't/a.t' );
    $send->( 3.5,   'baseline_test', test  => 't/b.t' );
    $send->( 7.5,   'tick' );
    $send->( 7.75,  'tick' );
    $send->( 8,     'baseline', tests => 1, jobs => 2 );
    $send->( 9.5,   'phase',    name  => 'mutants' );
    $send->( 14.5,  'tick' );
    $send->( 14.75, 'mutant', status => 'Killed' );
    $send->( 15.25, 'mutant', status => 'Survived' );
    $send->( 20,    'tick' );
    $send->( 20.25, 'tick' );
    $send->( 25.25, 'mutant',   status => 'Ignored' );
    $send->( 26.5,  'finished', total  => 20, counts => { Killed => 18, Survived => 2 } );
    $send->( 27,    'finished', total  => 20, counts => { Killed => 18, Survived => 2 } );
    $send->( 28,    'finished', total  => 20, counts => { Killed => 20 } );
    close $stream or die $!;
    is $output,
      join( "\n",
        'Resolve | 0s elapsed',
        'Analyze | 1s elapsed',
        '2 processors online',
        '20 mutants in 2 files, 3 tests',
        'Baseline (0/3 tests) | 2s elapsed',
        'Baseline (2/3 tests) | 7s elapsed',
        'The unmodified run passed: 1 test, 2 jobs',
        'Mutants | 9s elapsed',
        'Mutants | 14s elapsed',
        '[ 2/20] 1 killed, 1 survived | 15s elapsed, 51s remaining',
        '[ 2/20] 1 killed, 1 survived | 20s elapsed, 96s remaining',
        '[ 3/20] 1 killed, 1 survived, 1 ignored | 25s elapsed, 89s remaining',
        '[20/20] 18 killed, 2 survived | 26s elapsed',
        '[20/20] 20 killed | 28s elapsed',
        q{} ),
      'quiet periods update at the deadline and equal final counts appear once';
};

subtest 'a terminal overwrites a position and ends it before a message or the final count' => sub {
    my $now    = 50.5;
    my $output = q{};
    open my $stream, '>', \$output or die $!;
    my $view = Test::Mutation::Report::Live::listener( $stream, 1, 1, sub { $now }, 'one processor' );
    $view->( 'analyzed', { mutants => 2, files => 1, tests => 1 } );
    $view->( 'phase',    { name    => 'mutants' } );
    $now += 1.5;
    $view->( 'mutant', { status => 'Killed' } );
    like $output, qr/\r\[1\/2\] 1 killed [|] 1s elapsed, 1s remaining\z/,
      'the terminal position stays open until another message arrives';
    $view->( 'baseline', { tests => 2, jobs => 1 } );
    $now += 1.25;
    $view->( 'mutant',   { status => 'Survived' } );
    $view->( 'finished', { total  => 2, counts => { Killed => 1, Survived => 1 } } );
    close $stream or die $!;
    is $output,
        "one processor\n2 mutants in 1 file, 1 test\n\e[1mMutants\e[0m | 0s elapsed\n"
      . "\r[1/2] 1 killed | 1s elapsed, 1s remaining\nThe unmodified run passed: 2 tests, 1 job\n"
      . "\r[2/2] 1 killed, 1 survived | 2s elapsed\n",
      'the phase carries terminal emphasis and the completed line has one newline';
};

subtest 'phase events identify their start and only the measuring process publishes clock ticks' => sub {
    my @events;
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return 37.5 };
        for my $phase (qw(plan baseline mutants)) {
            Test::Mutation::Event::phase(
                sub ( $event, $data ) { push @events, [ $event, $data->{name}, $data->{time} ] }, $phase );
        }
    }
    is \@events,
      [
        [ qw(phase plan),                37.5 ],
        [ qw(phase baseline),            37.5 ],
        [ qw(baseline_started baseline), 37.5 ],
        [ qw(phase mutants),             37.5 ],
        [ qw(mutants_started mutants),   37.5 ]
      ],
      'the generic and stage-specific notifications carry the same time and phase';
    my ( $clock, @notifications ) = 100;
    no warnings 'redefine';
    local *Test::Mutation::Clock::now = sub { return $clock };
    Test::Mutation::Event::during(
        sub ( $event, $data ) { push @notifications, [ $event, $data->{time} ] },
        sub {
            $clock += 5;
            my $pid = fork;
            die "fork: $!" unless defined $pid;
            if ( !$pid ) {
                Test::Mutation::Event::checkpoint();
                POSIX::_exit( scalar @notifications );
            }
            waitpid $pid, 0;
            is $?, 0, 'a child leaves the inherited progress stream alone';
            Test::Mutation::Event::checkpoint();
            return 1;
        }
    );
    is \@notifications, [ [ tick => 105 ] ], 'the default clock publishes the parent tick';
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        Test::Mutation::Event::checkpoint();
    }
    is \@warnings, [], 'a checkpoint outside a watched run produces no diagnostic';
    isa_ok dies {
        Test::Mutation::Event::during( sub { }, 'work' )
    }, ['Error::TypeTiny'], 'a watch requires executable work';
    isa_ok dies { Test::Mutation::Event::checkpoint('extra') }, ['Error::TypeTiny'], 'a checkpoint takes no arguments';
    isa_ok dies {
        Test::Mutation::Report::Live::listener( [], 0, 0, sub { return 0 }, 'processors' )
    }, ['Error::TypeTiny'], 'the progress stream is checked when the listener is created';
    my $unopened = Symbol::gensym();
    is ref Test::Mutation::Report::Live::listener( $unopened, 0, 0, sub { return 0 }, 'processors' ), 'CODE',
      'an unopened glob can receive a listener before the caller attaches its stream';
};

done_testing;
