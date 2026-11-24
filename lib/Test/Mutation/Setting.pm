package Test::Mutation::Setting;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Bool Enum Maybe Str StrMatch Tuple);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

has name         => ( is => 'ro', isa => StrMatch [qr/\A[a-z][a-z_]*\z/], required => 1 );
has flag         => ( is => 'ro', isa => Maybe [ StrMatch [qr/\A--[a-z][a-z-]*\z/] ], default => undef );
has short        => ( is => 'ro', isa => Maybe [ StrMatch [qr/\A-[[:alpha:]]\z/] ],   default => undef );
has negatable    => ( is => 'ro', isa => Bool, default => 0 );
has key          => ( is => 'ro', isa => Maybe [ Tuple [ Str, Str ] ], default => undef );
has attribute    => ( is => 'ro', isa => Maybe [Str], default => undef );
has kind         => ( is => 'ro', isa => Enum [qw(flag value list)], required => 1 );
has type         => ( is => 'ro', isa => Str, required => 1 );
has default_text => ( is => 'ro', isa => Str, required => 1 );
has commands     => ( is => 'ro', isa => ArrayRef [Str], required => 1 );

1;

__END__

=head1 NAME

Test::Mutation::Setting - one setting and its name on each surface

=head1 SYNOPSIS

    my ($jobs) = grep { $_->name eq 'jobs' } Test::Mutation::Settings::rows()->@*;
    say join q{ }, $jobs->flag, $jobs->short, $jobs->kind;

=head1 DESCRIPTION

A setting reaches a run from the command line, from the configuration file, or from a call of the library.
A row states the name of the setting on each of the three surfaces, and nothing where a surface lacks it.
The rows describe the command as it stands, and the command reads none of them yet.

=head1 ATTRIBUTES

=head2 name

The name of the row.

=head2 flag, short, negatable

The long option, the short option, and whether the command line also takes the long option after C<--no->.

=head2 key

The section and the key of the configuration file, with an empty section for a key above every section.

=head2 attribute

The attribute of L<Test::Mutation::Config>, which is also the name in a call of the library.

=head2 kind

C<flag> for a setting without a value, C<value> for one value, and C<list> for a setting that the user may repeat.

=head2 type

The name of the set of values that the setting accepts.

=head2 default_text

The value that a run uses when no surface sets one, as text.

=head2 commands

The commands that accept the flag.

=cut
