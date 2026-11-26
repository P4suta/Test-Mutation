package Test::Mutation::Status;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Bool Enum InstanceOf Maybe Str StrMatch);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

# The statuses that version 2 of the report schema defines, which a report file may hold.
my @SCHEMA = qw(Killed Survived NoCoverage CompileError RuntimeError Timeout Ignored Pending);

has name        => ( is => 'ro', isa => Str, required => 1 );
has schema      => ( is => 'ro', isa => Enum [@SCHEMA], required => 1 );
has word        => ( is => 'ro', isa => Str, required => 1 );
has heading     => ( is => 'ro', isa => Maybe [Str], required => 1 );
has role        => ( is => 'ro', isa => Enum [qw(detected undetected outside)], required => 1 );
has progress    => ( is => 'ro', isa => Bool, required => 1 );
has annotation  => ( is => 'ro', isa => Maybe [ Enum [qw(warning notice)] ], required => 1 );
has cached      => ( is => 'ro', isa => Bool, required => 1 );
has reasons     => ( is => 'ro', isa => ArrayRef [ StrMatch [qr/\A[a-z]+(?:-[a-z]+)*\z/] ], required => 1 );
has description => ( is => 'ro', isa => Str, required => 1 );

# Each row: the name in the run, the name in the report schema, the counting word, the heading of its section,
# the role in the score, whether the progress line counts it, the level of its annotation, whether the cache keeps it,
# the reasons that it may carry, and what it means.
my @ROWS = (
    [ 'Killed', 'Killed', 'killed', undef, 'detected', 1, undef, 1, [], 'a test that loaded the mutant failed' ],
    [
        'Survived', 'Survived', 'survived', 'Survived', 'undetected', 1, 'warning', 1, [],
        'every test that loaded the mutant passed'
    ],
    [
        'NoCoverage', 'NoCoverage', 'no coverage', 'No coverage', 'undetected', 1, 'warning', 0,
        [qw(unreached not-loaded)],
        'no test loaded the mutant'
    ],
    [
        'Timeout', 'Ignored', 'timeout', 'Timeout', 'outside', 1, 'notice', 0,
        [qw(time-limit output-limit)],
        'a test that loaded the mutant exceeded its time limit or printed past its output limit, and no test failed'
    ],
    [
        'CompileError', 'CompileError',
        'compile error',
        'Compile errors',
        'outside', 1, undef, 1,
        [qw(parse compile-phase standalone)],
        'the mutated file fails to compile'
    ],
    [
        'NoVerdict',
        'RuntimeError',
        'no verdict',
        'No verdict',
        'outside',
        1, undef, 0,
        [
            qw(loaded-around-hook outside-copy no-record shim-error unstable-test conflicting-test project-changed),
            qw(build-copy-not-updated slot-not-restored)
        ],
        'the run could not decide, for the cause that the reason names'
    ],
    [
        'Ignored', 'Ignored', 'ignored', undef, 'outside', 0, undef, 1,
        [qw(suppressed same-code-as-original same-code-as-mutant)],
        'a comment suppressed the mutant, or it compiles to code that the run measured already'
    ],
    [
        'Pending', 'Pending', 'pending', undef, 'outside', 0, undef, 0, ['interrupted'],
        'the run ended before the mutant'
    ],
);

sub _row ( $name, $schema, $word, $heading, $role, $progress, $annotation, $cached, $reasons, $description ) {
    return __PACKAGE__->new(
        name        => $name,
        schema      => $schema,
        word        => $word,
        heading     => $heading,
        role        => $role,
        progress    => $progress,
        annotation  => $annotation,
        cached      => $cached,
        reasons     => $reasons,
        description => $description,
    );
}

my @CATALOG = map { _row( $_->@* ) } @ROWS;
my %ROW     = map { $_->name => $_ } @CATALOG;
my $NAME    = Enum [ map { $_->name } @CATALOG ];

signature_for rows => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Status'] ] );

sub rows () {
    return [@CATALOG];
}

signature_for names => ( positional => [], returns => ArrayRef [Str] );

sub names () {
    return [ map { $_->name } @CATALOG ];
}

signature_for of => ( positional => [$NAME], returns => InstanceOf ['Test::Mutation::Status'] );

sub of ($name) {
    return $ROW{$name};
}

signature_for fits => ( positional => [ $NAME, Maybe [Str] ], returns => Bool );

sub fits ( $name, $reason ) {
    my @reasons = $ROW{$name}->reasons->@*;
    return !defined $reason ? !@reasons : ( grep { $_ eq $reason } @reasons ) ? 1 : 0;
}

1;

__END__

=head1 NAME

Test::Mutation::Status - the catalog of the statuses of a mutant

=head1 SYNOPSIS

    for my $status ( Test::Mutation::Status::rows()->@* ) {
        say join q{: }, $status->name, $status->schema, $status->role;
    }
    my $timeout = Test::Mutation::Status::of('Timeout');
    my $fits    = Test::Mutation::Status::fits( 'Timeout', 'time-limit' );

=head1 DESCRIPTION

The catalog states every status once: its names, its words in the reports, its role in the score, whether the cache keeps it, and the reasons it may carry.
The score, the verdict, the result, the reports, and the cache read it, and no other place lists the statuses.

A status other than C<Killed> and C<Survived> carries a reason from the closed list of its row.
The report file writes the name of the schema as the status of a mutant, and the name in the run with its reason beside it.
A timeout is C<Ignored> in the schema, so a viewer of the report computes the score of the run.
A mutant without a verdict is C<RuntimeError> in the schema, which the viewer leaves out of the score as well.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Status> for every status, in the order of the reports.

=head2 names

Returns the name of every status, in the order of the reports.

=head2 of

Returns the row of a status name, and dies for another name.

=head2 fits

True when a reason belongs to a status: no reason for a status without reasons, and a reason of its list otherwise.

=head1 ATTRIBUTES

=head2 name

The name of the status in the run, in the cache, and under C<testMutation> in the report file.

=head2 schema

The name of the status in the report schema, which the report file writes as the status of a mutant.

=head2 word

The word that counts the status in the terminal report and in the progress line.

=head2 heading

The heading of the section that lists the mutants of the status in the terminal report, or undefined.

=head2 role

C<detected> and C<undetected> for the two sides of the score, and C<outside> for a status that the score leaves out.

=head2 progress

True when the progress line counts the status.

=head2 annotation

The level of the annotation that GitHub Actions gets for a mutant of the status, or undefined.

=head2 cached

True when the cache keeps a result of the status.

=head2 reasons

The reasons that a mutant of the status may carry, or none for a status that needs no reason.

=head2 description

What the status says about a mutant.

=cut
