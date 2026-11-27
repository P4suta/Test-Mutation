package Test::Mutation::Error;
use v5.36;
use Moo;
use Types::Standard qw(Enum HashRef Slurpy Str Undef);
use Type::Params    qw(signature_for);
use Test::Mutation::Message;

use overload q{""} => sub ( $self, @ ) { return $self->message . "\n" }, fallback => 1;

our $VERSION = '0.001';

with 'Test::Mutation::Value';

has kind    => ( is => 'ro', isa => Enum [qw(usage environment)], required => 1 );
has id      => ( is => 'ro', isa => Str, required => 1 );
has message => ( is => 'ro', isa => Str, required => 1 );

signature_for raise => ( positional => [ Str, Slurpy [ HashRef [Str] ] ], returns => Undef );

sub raise ( $id, $values ) {
    my $message = Test::Mutation::Message::text_of( $id, $values->%* );
    die __PACKAGE__->new( kind => Test::Mutation::Message::row($id)->kind, id => $id, message => $message );    ## no critic (ErrorHandling::RequireCarping)
}

1;

__END__

=head1 NAME

Test::Mutation::Error - a failure that the tool reports to its user

=head1 SYNOPSIS

    open my $handle, '<', $path
      or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );

=head1 DESCRIPTION

An error is an immutable value that the library dies with.
Its words come from L<Test::Mutation::Message>, so the code that raises it names a message and gives its values.
The command ends an error of the kind C<usage> with status 2 and one of the kind C<environment> with status 5.
Every other exception is a defect of the tool, which the command ends with status 6.
An error reads as its message on a line of its own where a text is asked for.

=head1 FUNCTIONS

=head2 raise

    Test::Mutation::Error::raise( 'mutant-unknown', identifier => $identifier );

Dies with the error of a message of the catalog, with the given values in the slots of its text.
The message must have the kind C<usage> or C<environment>.

=head1 ATTRIBUTES

=head2 kind

C<usage> for a request that the tool refuses, and C<environment> for a file, Git, or a process that failed.

=head2 id

The identifier of the message in the catalog.

=head2 message

The text for the user, on one line and without a newline at its end.

=cut
