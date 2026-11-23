package Permutl::Result;
use v5.36;
use Moo;
use Types::Standard        qw(ArrayRef Bool Dict Enum HashRef InstanceOf Int Maybe Num Str StrMatch);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);
use Permutl::Score;

our $VERSION = '0.001';

my $STATUS = Enum [qw(Killed Survived NoCoverage Timeout CompileError RuntimeError Ignored Pending)];
my $ENTRY  = Dict [
    mutant     => InstanceOf ['Permutl::Mutant'],
    status     => $STATUS,
    reason     => Maybe [Str],
    by         => Maybe [Str],
    covered_by => ArrayRef [Str],
    tests_run  => Int,
    duration   => Num,
];

has root     => ( is => 'ro', isa => Str, required => 1 );
has sources  => ( is => 'ro', isa => HashRef [Str], required => 1 );
has tests    => ( is => 'ro', isa => ArrayRef [ Dict [ name => Str, duration => Num ] ], required => 1 );
has entries  => ( is => 'ro', isa => ArrayRef [$ENTRY], required => 1 );
has problems => ( is => 'ro', isa => ArrayRef [ Dict [ path => Str, problem => Str ] ], required => 1 );
has warnings => ( is => 'ro', isa => ArrayRef [Str], required => 1 );
has baseline_failures =>
  ( is => 'ro', isa => ArrayRef [ Dict [ test => Str, output => Str, errors => Str ] ], required => 1 );
has jobs          => ( is => 'ro', isa => PositiveInt, required => 1 );
has parallel_safe => ( is => 'ro', isa => Bool,        required => 1 );
has interrupted   => ( is => 'ro', isa => Maybe [ Enum [qw(HUP INT TERM)] ], default => undef );
has reused        => ( is => 'ro', isa => Int, default => 0 );
has shard         => ( is => 'ro', isa => Maybe [ StrMatch [qr{\A[1-9][0-9]*/[1-9][0-9]*\z}] ], default => undef );
has inventory =>
  ( is => 'ro', isa => Maybe [ Dict [ mutants => Int, digest => StrMatch [qr/\A[0-9a-f]{64}\z/] ] ], default => undef );
has started  => ( is => 'ro', isa => Num, required => 1 );
has finished => ( is => 'ro', isa => Num, required => 1 );

signature_for tally => (
    method     => 1,
    positional => [],
    returns    => Dict [ counts => HashRef [Int], total => Int, valid => Int, score => Maybe [Num] ],
);

sub tally ($self) {
    return Permutl::Score::tally( [ map { $_->{status} } $self->entries->@* ] );
}

signature_for conclusive => ( method => 1, positional => [], returns => Bool );

sub conclusive ($self) {
    my $tally = $self->tally;
    return 0 if $self->baseline_failures->@* || defined $self->interrupted;
    return 0 if $tally->{counts}{RuntimeError};
    return 0 if $tally->{total} - $tally->{counts}{Ignored} > 0 && !$tally->{valid};
    return 1;
}

1;

__END__

=head1 NAME

Permutl::Result - the outcome of a run

=head1 ATTRIBUTES

=head2 root

The project directory.

=head2 sources

Maps the path of every analyzed source file to its text.

=head2 tests

The tests of the unmodified run with their durations in seconds.

=head2 entries

One entry for every mutant: the mutant, its status, the reason, the deciding test, the selected tests, the number of tests that ran, and the time they took.

=head2 problems

The source files that were left out, with the reason.

=head2 warnings

Conditions that weaken the measurement without stopping it.

=head2 baseline_failures

The tests that fail in the unmodified run, with their output.
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

=head2 shard

The part of the mutants that the run covered, such as C<2/4>, or undefined for a whole run.

=head2 inventory

The count of the mutants before the split into parts, and the SHA-256 digest of their identifiers.
Two results with the same inventory measured the same mutants of the same sources.

=head2 started, finished

Epoch seconds.

=head1 METHODS

=head2 tally

Returns the status counts and the score, as L<Permutl::Score/tally> does.

=head2 conclusive

True when the run measured something: the unmodified run passed, no mutant ended in C<RuntimeError>, and at least one mutant is valid when any mutant ran.

=cut
