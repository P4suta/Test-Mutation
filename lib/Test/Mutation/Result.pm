package Test::Mutation::Result;
use v5.36;
use Moo;
use Types::Standard        qw(ArrayRef Bool Dict Enum HashRef Int Maybe Num Optional Str StrMatch);
use Types::Common::Numeric qw(PositiveInt PositiveOrZeroInt);
use Type::Params           qw(signature_for);
use Test::Mutation::Exit;
use Test::Mutation::Score;
use Test::Mutation::Status;
use Test::Mutation::Types qw(Entry);

our $VERSION = '0.001';

has root     => ( is => 'ro', isa => Str, required => 1 );
has sources  => ( is => 'ro', isa => HashRef [Str], required => 1 );
has tests    => ( is => 'ro', isa => ArrayRef [ Dict [ name => Str, duration => Num ] ], required => 1 );
has entries  => ( is => 'ro', isa => ArrayRef [Entry], required => 1 );
has problems => ( is => 'ro', isa => ArrayRef [ Dict [ path => Str, problem => Str ] ], required => 1 );
has warnings => ( is => 'ro', isa => ArrayRef [Str], required => 1 );
has baseline_failures => (
    is  => 'ro',
    isa => ArrayRef [
        Dict [
            test   => Str,
            output => Str,
            errors => Str,
            reason => Optional [ Enum [ Test::Mutation::Status::of('Timeout')->reasons->@* ] ]
        ]
    ],
    required => 1
);
has jobs          => ( is => 'ro', isa => PositiveInt, required => 1 );
has parallel_safe => ( is => 'ro', isa => Bool,        required => 1 );
has interrupted   => ( is => 'ro', isa => Maybe [ Enum [ Test::Mutation::Exit::signals()->@* ] ], default => undef );
has reused        => ( is => 'ro', isa => Int,  default => 0 );
has in_copies     => ( is => 'ro', isa => Bool, default => 0 );
has shard         => ( is => 'ro', isa => Maybe [ StrMatch [qr{\A[1-9][0-9]*/[1-9][0-9]*\z}] ], default => undef );
has inventory =>
  ( is => 'ro', isa => Maybe [ Dict [ mutants => Int, digest => StrMatch [qr/\A[0-9a-f]{64}\z/] ] ], default => undef );
has started  => ( is => 'ro', isa => Num, required => 1 );
has finished => ( is => 'ro', isa => Num, required => 1 );

my @WORK = qw(copies walks compiles spawns listings baseline_tests verifications);
has stats => (
    is      => 'ro',
    isa     => Dict [ map { $_ => PositiveOrZeroInt } @WORK ],
    default => sub {
        return { map { $_ => 0 } @WORK };
    },
);

signature_for tally => (
    method     => 1,
    positional => [],
    returns    => Dict [ counts => HashRef [Int], total => Int, valid => Int, score => Maybe [Num] ],
);

sub tally ($self) {
    return Test::Mutation::Score::tally( [ map { $_->{status} } $self->entries->@* ] );
}

signature_for conclusive => ( method => 1, positional => [], returns => Bool );

sub conclusive ($self) {
    my $tally = $self->tally;
    return 0 if $self->baseline_failures->@* || defined $self->interrupted;
    return 0 if $tally->{counts}{NoVerdict};
    return 0 if $tally->{total} - $tally->{counts}{Ignored} > 0 && !$tally->{valid};
    return 1;
}

1;

__END__

=head1 NAME

Test::Mutation::Result - the outcome of a run

=head1 ATTRIBUTES

=head2 root

The project directory.

=head2 sources

Maps the path of every analyzed source file to its text.

=head2 tests

The tests of the unmodified run with their durations in seconds.

=head2 entries

One entry for every mutant, of the type C<Entry> of L<Test::Mutation::Types>: the mutant, its status, the reason that its status calls for, a sentence about the case, the deciding test, the selected tests, the number of tests that ran, and the time they took.

=head2 problems

The source files that were left out, with the reason.

=head2 warnings

Conditions that weaken the measurement without stopping it, each once and in the order of their text.

=head2 baseline_failures

The tests that fail in the unmodified run, with their output.
A test that a limit of the pool ended carries the reason of a timeout for that limit, C<time-limit> or C<output-limit>.
A run with baseline failures has no entries.

=head2 jobs

The number of test processes that ran side by side.

=head2 parallel_safe

False when the tests passed one at a time and failed side by side.

=head2 interrupted

The name of the signal that ended the run early, or undefined.
The mutants that did not finish have the status C<Pending>.

=head2 reused

The number of entries that came from the cache of an earlier run.

=head2 in_copies

True when the tests ran in copies of the project, and false when they ran in the project itself.

=head2 shard

The part of the mutants that the run covered, such as C<2/4>, or undefined for a whole run.

=head2 inventory

The count of the mutants before the split into parts, and the SHA-256 digest of their identifiers.
Two results with the same inventory measured the same mutants of the same sources.

=head2 started, finished

Epoch seconds.

=head2 stats

The work of the run, as counts that a busy machine leaves the same.
C<copies> counts the copies of the project, and C<walks> the walks over a tree that record its state.
C<compiles> counts the processes that compile a file without its tests: the syntax checks and the decompiled code.
C<spawns> counts every process that the pool started, and C<listings> every list of processes that it read before it ended a test.
C<baseline_tests> counts the runs of tests in the unmodified run, and C<verifications> the runs that check the unmodified run once more.
Such a run follows a failure of tests side by side and a change of the project by the mutants.

=head1 METHODS

=head2 tally

Returns the status counts and the score, as L<Test::Mutation::Score/tally> does.

=head2 conclusive

True when the run measured something: the unmodified run passed, every mutant has a verdict, and at least one mutant is valid when any mutant ran.

=cut
