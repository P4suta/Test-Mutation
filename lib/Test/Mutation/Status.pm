package Test::Mutation::Status;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Bool Enum InstanceOf Maybe Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

has name       => ( is => 'ro', isa => Str, required => 1 );
has word       => ( is => 'ro', isa => Str, required => 1 );
has heading    => ( is => 'ro', isa => Maybe [Str], required => 1 );
has role       => ( is => 'ro', isa => Enum [qw(detected undetected outside)], required => 1 );
has progress   => ( is => 'ro', isa => Bool, required => 1 );
has annotation => ( is => 'ro', isa => Maybe [ Enum [qw(warning notice)] ], required => 1 );
has cached     => ( is => 'ro', isa => Bool, required => 1 );

# Each row: the name, the counting word, the heading of its section, the role in the score,
# whether the progress line counts it, the level of its annotation, and whether the cache keeps it.
my @ROWS = (
    [ 'Killed',       'killed',        undef,           'detected',   1, undef,     1 ],
    [ 'Survived',     'survived',      'Survived',      'undetected', 1, 'warning', 1 ],
    [ 'NoCoverage',   'no coverage',   'No coverage',   'undetected', 1, 'warning', 0 ],
    [ 'Timeout',      'timeout',       'Timeout',       'outside',    1, 'notice',  0 ],
    [ 'CompileError', 'compile error', undef,           'outside',    1, undef,     1 ],
    [ 'RuntimeError', 'runtime error', 'Runtime error', 'outside',    1, undef,     0 ],
    [ 'Ignored',      'ignored',       undef,           'outside',    0, undef,     1 ],
    [ 'Pending',      'pending',       undef,           'outside',    0, undef,     0 ],
);

sub _row ( $name, $word, $heading, $role, $progress, $annotation, $cached ) {
    return __PACKAGE__->new(
        name       => $name,
        word       => $word,
        heading    => $heading,
        role       => $role,
        progress   => $progress,
        annotation => $annotation,
        cached     => $cached,
    );
}

signature_for rows => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Status'] ] );

sub rows () {
    return [ map { _row( $_->@* ) } @ROWS ];
}

1;

__END__

=head1 NAME

Test::Mutation::Status - the table of the statuses of a mutant

=head1 SYNOPSIS

    for my $status ( Test::Mutation::Status::rows()->@* ) {
        say join q{: }, $status->name, $status->role;
    }

=head1 DESCRIPTION

The table states every status once, with what the score, the reports, and the cache do with it.
It describes the code as it stands, where each of those modules holds a list of its own.
A test compares the table with what the modules do.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Status> for every status, in the order of the reports.

=head1 ATTRIBUTES

=head2 name

The name of the status, as the report file writes it.

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

=cut
