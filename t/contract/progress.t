use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::CLI;
use Test::Mutation::Runner;
use Test::Mutation::Status;

# S7, the progress: every sequence of up to four statuses, on a terminal and in a log.
# No test runs: the run sends the events of a made sequence, and the command prints its progress lines.

my @statuses = Test::Mutation::Status::rows()->@*;
my %word     = map { $_->name => $_->word } @statuses;
my $longest  = 4;
my $scratch  = Space::scratch();
my $plan     = World::observe( [ 'run', '--config', 'quiet.toml' ], cwd => $scratch, run => 'cheap' )->{plan};
my $nothing  = Samples::result( statuses => [] );
my %stream   = ( 0 => 'log', 1 => 'terminal' );
my %violations;

# What the command prints to standard error while a run sends its events.
# The run calls `work` once for each step of its work, with the text that the command has printed so far.
sub printed ( $terminal, $events, $clock = sub { 0 } ) {
    my $text = q{};
    open my $errors, '>', \$text or die "open: $!";
    my $world =
      { World::facts( cwd => $scratch, err_tty => $terminal, clock => $clock ), out => $errors, err => $errors };
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub ( $config, $listener, $options ) {
        $events->( $listener, sub { return length $text } );
        return $nothing;
    };
    Test::Mutation::CLI::execute( $plan, $world );
    return $text;
}

# The progress lines of a sequence of statuses: the command prints one after each mutant.
sub progress_lines ( $terminal, $sequence ) {
    my $text = printed(
        $terminal,
        sub ( $listener, $length ) {
            $listener->( 'analyzed', { mutants => scalar $sequence->@*, files => 1, tests => 1 } );
            $listener->( 'mutant',   { status  => $_ } ) for $sequence->@*;
        }
    );
    return [ grep { /\A\[/ } split /[\r\n]+/, $text ];
}

subtest 'the progress of a made run rejects a line that drops a mutant' => sub {
    is progress_lines( 0, [qw(Killed Survived)] ), [ '[1/2] 1 killed', '[2/2] 1 killed, 1 survived' ],
      'the lines of a log';
    is progress_lines( 1, [qw(Killed Survived)] ), [ '[1/2] 1 killed', '[2/2] 1 killed, 1 survived' ],
      'the lines of a terminal';
    is [ Invariants::progress_sum( progress_lines( 0, [qw(Killed Killed)] ) ) ], [], 'two counted mutants';
    is [ Invariants::progress_sum( [ '[1/2] 1 killed', '[2/2] 1 killed' ] ) ],
      ['the counts of a line sum to less than its position'],
      'a line that leaves a mutant out';
};

my @sequences = ( [] );
my @grown     = ( [] );
for my $length ( 1 .. $longest ) {
    my @longer;
    for my $head (@grown) {
        push @longer, map { [ $head->@*, $_->name ] } @statuses;
    }
    @grown = @longer;
    push @sequences, @grown;
}

my $count = 0;
for my $terminal ( 0, 1 ) {
    for my $sequence (@sequences) {
        my $lines = progress_lines( $terminal, $sequence );
        my %counts;
        $counts{$_}++ for $sequence->@*;
        $count++;
        push $violations{'progress-sum'}->@*,
          map { [ $_, scalar $sequence->@*, $stream{$terminal} ] } Invariants::progress_sum($lines);
        push $violations{'progress-final'}->@*,
          map { [ 'the last line states another count than the result', $_, $stream{$terminal} ] }
          Invariants::progress_final( $lines, \%counts, \%word );
    }
}

my $expected = 0;
$expected += @statuses**$_ for 0 .. $longest;
is scalar @sequences, $expected,     'every sequence of the statuses of the table, up to four';
is $count,            2 * $expected, 'each sequence on a terminal and in a log';
Gate::checked( 'sequences of statuses', $count, at_least => 9000 );

# The silence of a run in steps of its work: the tests of the unmodified run, and the mutants.
# The injected clock advances one second at each checkpoint, even when a test has printed nothing.
sub silences ( $terminal, $size, $ticks = 1 ) {
    my $now     = 0;
    my %silence = ( baseline => 0, mutants => 0 );
    printed(
        $terminal,
        sub ( $listener, $length ) {
            my ( $quiet, $seen ) = ( 0, 0 );
            my $step = sub ( $phase, @event ) {
                $quiet++;
                $now++;
                $listener->(@event)       if @event;
                $listener->( 'tick', {} ) if $ticks;
                return                    if $length->() == $seen;
                $silence{$phase} = $quiet if $quiet > $silence{$phase};
                ( $quiet, $seen ) = ( 0, $length->() );
            };
            $listener->( 'analyzed', { mutants => $size, files => 1, tests => $size } );
            $listener->( 'phase',    { name    => 'baseline' } );
            $seen = $length->();
            $step->('baseline') for 2 .. $size;
            $step->( 'baseline', 'baseline', { tests => $size, jobs => 1 } );
            $listener->( 'phase', { name => 'mutants' } );
            $seen = $length->();
            $step->( 'mutants', 'mutant', { status => 'Killed' } ) for 1 .. $size;
        },
        sub { $now }
    );
    return \%silence;
}

subtest 'the silence of a made run rejects a phase that prints nothing' => sub {
    is silences( 1, 10 ), { baseline => 5, mutants => 1 },
      'a terminal reports a quiet baseline and prints every mutant';
    is silences( 0, 10 ), { baseline => 5, mutants => 1 }, 'a log of a small run prints every mutant';
    is [ Invariants::liveness( silences( 1, 10 )->{mutants}, silences( 1, 1000 )->{mutants} ) ], [],
      'the mutants on a terminal';
    is [ Invariants::liveness( silences( 1, 10, 0 )->{baseline}, silences( 1, 1000, 0 )->{baseline} ) ],
      ['the display is silent for more than five seconds'],
      'an unmodified run with a broken heartbeat';
};

my @sizes  = ( 10, 1000 );
my $phases = 0;
for my $terminal ( 0, 1 ) {
    my ( $small, $large ) = map { silences( $terminal, $_ ) } @sizes;
    for my $phase ( sort keys $small->%* ) {
        $phases++;
        push $violations{liveness}->@*,
          map { [ $_, $phase, $stream{$terminal} ] } Invariants::liveness( $small->{$phase}, $large->{$phase} );
    }
}
Gate::checked( 'phases of a run on a stream', $phases, at_least => 4 );

Gate::findings( 'contract-progress-sum-progress',
    Space::folded( $violations{'progress-sum'} || [], 'lengths', 'streams' ) );
Gate::findings( 'contract-progress-final-progress',
    Space::folded( $violations{'progress-final'} || [], 'statuses', 'streams' ) );
Gate::findings( 'contract-liveness-progress', Space::folded( $violations{liveness} || [], 'phases', 'streams' ) );

done_testing;
