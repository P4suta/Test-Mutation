package Test::Mutation::Coverage;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Bool Dict Enum HashRef InstanceOf Num Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my $LINES = HashRef [Bool];

has mode => ( is => 'ro', isa => Enum [qw(line file)], required => 1 );
has tests => (
    is       => 'ro',
    isa      => HashRef [ Dict [ duration => Num, files => HashRef [ Dict [ traced => Bool, hits => $LINES ] ] ] ],
    required => 1,
);
has breakable => ( is => 'ro', isa => HashRef [$LINES], required => 1 );

signature_for tests_for => (
    method     => 1,
    positional => [ InstanceOf ['Test::Mutation::Mutant'] ],
    returns    => ArrayRef [Str],
);

sub tests_for ( $self, $mutant ) {
    my $path     = $mutant->path;
    my $tests    = $self->tests;
    my @loading  = grep { exists $tests->{$_}{files}{$path} } keys $tests->%*;
    my @lines    = $mutant->scope->[0] .. $mutant->scope->[1];
    my @selected = @loading;
    if ( $self->mode eq 'line' && $self->_observable( $path, \@lines, \@loading ) ) {
        @selected = grep { $self->_reaches( $tests->{$_}{files}{$path}, \@lines ) } @loading;
    }
    return [ sort { $tests->{$a}{duration} <=> $tests->{$b}{duration} || $a cmp $b } @selected ];
}

sub _reaches ( $self, $file, $lines ) {
    return 1 if !$file->{traced};
    return scalar grep { $file->{hits}{$_} } $lines->@*;
}

sub _observable ( $self, $path, $lines, $loading ) {
    my $breakable = $self->breakable->{$path};
    return 1 if $breakable && grep { $breakable->{$_} } $lines->@*;
    for my $test ( $loading->@* ) {
        my $hits = $self->tests->{$test}{files}{$path}{hits};
        return 1 if grep { $hits->{$_} } $lines->@*;
    }
    return 0;
}

1;

__END__

=head1 NAME

Test::Mutation::Coverage - choose the tests that can detect a mutant

=head1 SYNOPSIS

    my $coverage = Test::Mutation::Coverage->new( mode => 'line', tests => \%tests, breakable => \%breakable );
    my @tests = $coverage->tests_for($mutant)->@*;

=head1 DESCRIPTION

The coverage holds what every test loaded and ran in the unmodified run.
A test can detect a mutant when it loaded the file and, in C<line> mode, ran a line of the statement that holds the mutant.

Line data is trusted where it can be observed.
A statement with no runtime line, such as code that runs at compile time, falls back to every test that loaded the file.
A test whose processes were not all tracing counts as reaching every line of the file.

=head1 ATTRIBUTES

=head2 mode

C<line> or C<file>.

=head2 tests

Maps a test name to its duration and the files it loaded.

=head2 breakable

Maps a file to the lines that hold a runtime statement.

=head1 METHODS

=head2 tests_for

Returns the names of the tests that can detect the mutant, fastest first.

=cut
