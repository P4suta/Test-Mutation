package Permutl::Mutator;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef CodeRef Dict Enum InstanceOf Str StrMatch);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

has name        => ( is => 'ro', isa => StrMatch [qr/\A[a-z][a-z-]*\z/], required => 1 );
has profile     => ( is => 'ro', isa => Enum [qw(default extended)], required => 1 );
has description => ( is => 'ro', isa => Str,     required => 1 );
has _generate   => ( is => 'ro', isa => CodeRef, init_arg => 'generate', required => 1 );

signature_for mutations => (
    method     => 1,
    positional => [ InstanceOf ['Permutl::Site'] ],
    returns    => ArrayRef [ Dict [ replacement => Str, description => Str ] ],
);

sub mutations ( $self, $site ) {
    return [ grep { $_->{replacement} ne $site->text } $self->_generate->($site) ];
}

1;

__END__

=head1 NAME

Permutl::Mutator - a named rule that proposes replacements for a site

=head1 SYNOPSIS

    my $mutator = Permutl::Mutator->new(
        name        => 'arithmetic',
        profile     => 'default',
        description => 'Replaces an arithmetic operator with its counterpart',
        generate    => sub ($site) {
            return if $site->kind ne 'operator' || $site->text ne '+';
            return { replacement => '-', description => 'replaced + with -' };
        },
    );
    my @mutations = $mutator->mutations($site)->@*;

=head1 DESCRIPTION

A mutator turns one L<Permutl::Site> into zero or more replacement texts.
The C<generate> callback is a pure function of the site.

=head1 ATTRIBUTES

=head2 name

A lowercase name with hyphens, used in configuration and in C<## no mutate> comments.

=head2 profile

C<default> for mutators that run without configuration, C<extended> for the ones a project turns on.

=head2 description

One sentence for reports and listings.

=head1 METHODS

=head2 mutations

Returns the replacements for a site, leaving out any that equal the original text.

=cut
