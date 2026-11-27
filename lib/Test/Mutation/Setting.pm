package Test::Mutation::Setting;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Bool CodeRef Enum InstanceOf Maybe Str StrMatch);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

my $SURFACE = Enum [qw(line file call)];

has name         => ( is => 'ro', isa => StrMatch [qr/\A[a-z]+(?:-[a-z]+)*\z/], required => 1 );
has short        => ( is => 'ro', isa => Maybe [ StrMatch [qr/\A-[[:alpha:]]\z/] ], default => undef );
has kind         => ( is => 'ro', isa => Enum [qw(flag value list)], required => 1 );
has type         => ( is => 'ro', isa => InstanceOf ['Type::Tiny'], required => 1 );
has expects      => ( is => 'ro', isa => Str, required => 1 );
has placeholder  => ( is => 'ro', isa => Maybe [ StrMatch [qr/\A[A-Z]+(?:\/[A-Z]+)?\z/] ], default => undef );
has default      => ( is => 'ro', isa => Maybe [CodeRef], required => 1 );
has default_text => ( is => 'ro', isa => Str, required => 1 );
has help         => ( is => 'ro', isa => Str, required => 1 );
has group        => ( is => 'ro', isa => Enum [qw(project selection tests mutators report cache)], required => 1 );
has surfaces     => ( is => 'ro', isa => ArrayRef [$SURFACE], required => 1 );
has selects      => ( is => 'ro', isa => Bool, default => 0 );

signature_for flag => ( method => 1, positional => [], returns => Str );

sub flag ($self) {
    return q{--} . $self->name;
}

signature_for key => ( method => 1, positional => [], returns => Str );

sub key ($self) {
    return $self->name;
}

signature_for attribute => ( method => 1, positional => [], returns => Str );

sub attribute ($self) {
    return $self->name =~ tr/-/_/r;
}

signature_for offers => ( method => 1, positional => [$SURFACE], returns => Bool );

sub offers ( $self, $surface ) {
    return ( grep { $_ eq $surface } $self->surfaces->@* ) ? 1 : 0;
}

signature_for spelled => ( method => 1, positional => [$SURFACE], returns => Str );

sub spelled ( $self, $surface ) {
    my %spelled = ( line => $self->flag, file => $self->key, call => $self->attribute );
    return $spelled{$surface};
}

signature_for value_type => ( method => 1, positional => [], returns => InstanceOf ['Type::Tiny'] );

# A setting without a default may stay unset, and a list holds any number of values of the type.
sub value_type ($self) {
    my $type = $self->type;
    return ArrayRef [$type] if $self->kind eq 'list';
    return defined $self->default ? $type : Maybe [$type];
}

1;

__END__

=head1 NAME

Test::Mutation::Setting - one setting, under one name on every surface

=head1 SYNOPSIS

    my ($jobs) = grep { $_->name eq 'jobs' } Test::Mutation::Settings::rows()->@*;
    say join q{ }, $jobs->flag, $jobs->short, $jobs->key, $jobs->attribute;    # --jobs -j jobs jobs

=head1 DESCRIPTION

A setting reaches a run from the command line, from the configuration file, or from a call of the library.
Its name is the same on all three: the flag adds two dashes, and the argument of a call writes each hyphen as an underscore.
L<Test::Mutation::Settings> holds one row for each setting.

=head1 ATTRIBUTES

=head2 name

The name of the setting, lowercase words with hyphens between them.

=head2 short

The short option of the command line, or nothing.

=head2 kind

C<flag> for a setting that is on or off, C<value> for one value, and C<list> for a setting that the user may repeat.

=head2 type

The type of one value.

=head2 expects

The values that the setting takes, as an error message names them.

=head2 placeholder

The word that stands for the value in the help text, or nothing for a flag.

=head2 default

The code that gives the value of a run that no surface sets, from the facts of the run.
A setting without a value unless a surface gives one has no code.

=head2 default_text

The default as the help text and the manual state it.

=head2 help

The line that the help text prints for the setting.

=head2 group

The part of a run that the setting belongs to: C<project>, C<selection>, C<tests>, C<mutators>, C<report>, or C<cache>.

=head2 surfaces

The surfaces that offer the setting: C<line> for the command line, C<file> for the configuration file, and C<call> for the library.

=head2 selects

True for a setting that narrows the run to a part of its mutants.

=head1 METHODS

=head2 flag, key, attribute

The name on the command line, in the configuration file, and in a call of the library: C<--min-score>, C<min-score>, and C<min_score>.

=head2 offers

    my $in_the_file = $setting->offers('file');

True when the surface offers the setting.

=head2 spelled

    my $flag = $setting->spelled('line');

The name of the setting on a surface.

=head2 value_type

The type of the value of a run: a list of the type, the type, or the type or nothing for a setting without a default.

=cut
