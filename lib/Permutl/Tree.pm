package Permutl::Tree;
use v5.36;
use File::Find      ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef HashRef Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

signature_for snapshot => (
    named   => [ root => Str, skip => ArrayRef [Str] ],
    returns => HashRef [Str],
);

sub snapshot ($arg) {
    my $root = $arg->root;
    my %skip = map { $_ => 1 } $arg->skip->@*;
    my %state;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if $File::Find::name eq $root;
                my $path = substr $File::Find::name, 1 + length $root;
                if ( $skip{$path} ) {
                    $File::Find::prune = 1;
                    return;
                }
                $state{$path} = _signature($File::Find::name);
                return;
            },
        },
        $root,
    );
    return \%state;
}

# The size and the time of a file stand for its content, which keeps the walk of a large tree short.
sub _signature ($path) {
    my @status = Time::HiRes::lstat($path) or return 'gone';
    return 'link ' . readlink $path if -l _;
    return 'directory'              if -d _;
    return "file $status[7] $status[9]";
}

signature_for changes => ( positional => [ HashRef [Str], HashRef [Str] ], returns => ArrayRef [Str] );

sub changes ( $before, $after ) {
    my %seen  = ( $before->%*, $after->%* );
    my @lines = map {
            !exists $before->{$_}         ? "created $_"
          : !exists $after->{$_}          ? "removed $_"
          : $before->{$_} ne $after->{$_} ? "changed $_"
          : ()
    } sort keys %seen;
    return \@lines;
}

1;

__END__

=head1 NAME

Permutl::Tree - tell whether the files of a project changed

=head1 SYNOPSIS

    my $before = Permutl::Tree::snapshot( root => $root, skip => [ '.git', '.permutl' ] );
    ...
    my $changes = Permutl::Tree::changes( $before, Permutl::Tree::snapshot( root => $root, skip => [ '.git', '.permutl' ] ) );

=head1 DESCRIPTION

A mutant runs with the rights of the tests, so it may create, change, or remove a file of the project.
The run compares the state of the project before and after the mutants to find such a change.

=head1 FUNCTIONS

=head2 snapshot

Returns a signature for every file, directory, and link below C<root>, keyed by its path from the root.
A path in C<skip> is left out with all it holds.
The signature of a file holds its size and its modification time, and no digest of its content.

=head2 changes

Compares two states and returns one line for each path that was created, removed, or changed, in the order of the paths.

=cut
