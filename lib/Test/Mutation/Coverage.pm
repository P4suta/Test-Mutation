package Test::Mutation::Coverage;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Bool Dict Enum HashRef InstanceOf Num Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

my $LINES = HashRef [Bool];

has mode => ( is => 'ro', isa => Enum [qw(line file)], required => 1 );
has tests => (
    is       => 'ro',
    isa      => HashRef [ Dict [ duration => Num, files => HashRef [ Dict [ traced => Bool, hits => $LINES ] ] ] ],
    required => 1,
);
has breakable => ( is => 'ro', isa => HashRef [$LINES], required => 1 );

has _index => (
    is       => 'lazy',
    init_arg => undef,
    builder  => sub ($self) { return $self->_index_files },
    isa => HashRef [ Dict [ loading => ArrayRef [Str], blind => ArrayRef [Str], hits => HashRef [ ArrayRef [Str] ] ] ],
);

signature_for tests_for => (
    method     => 1,
    positional => [ InstanceOf ['Test::Mutation::Mutant'] ],
    returns    => ArrayRef [Str],
);

sub tests_for ( $self, $mutant ) {
    my $path = $mutant->path;
    my $file = $self->_index->{$path} or return [];
    return [ $file->{loading}->@* ] if $self->mode eq 'file';
    my %selected   = map { $_ => 1 } $file->{blind}->@*;
    my $breakable  = $self->breakable->{$path} || {};
    my $observable = 0;
    for my $line ( $mutant->scope->[0] .. $mutant->scope->[1] ) {
        my $hits = $file->{hits}{$line} || [];
        $observable   = 1 if $breakable->{$line} || $hits->@*;
        $selected{$_} = 1 for $hits->@*;
    }
    return $observable ? [ sort keys %selected ] : [ $file->{loading}->@* ];
}

sub _index_files ($self) {
    my %by_file;
    my $tests = $self->tests;
    for my $name ( sort keys $tests->%* ) {
        my $files = $tests->{$name}{files};
        for my $path ( keys $files->%* ) {
            my $file = $by_file{$path} ||= { loading => [], blind => [], hits => {} };
            push $file->{loading}->@*, $name;
            my $trace = $files->{$path};
            push $file->{blind}->@*,    $name unless $trace->{traced};
            push $file->{hits}{$_}->@*, $name for grep { $trace->{hits}{$_} } keys $trace->{hits}->%*;
        }
    }
    return \%by_file;
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

Returns the tests that can detect the mutant in ascending order of their project-relative paths.

=cut
