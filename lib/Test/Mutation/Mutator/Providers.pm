package Test::Mutation::Mutator::Providers;
use v5.36;
use Types::Standard qw(ArrayRef Bool Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my @QUANTIFIERS = qw(all any none notall);
my @REDUCERS    = qw(all any first max maxstr min minstr none notall);
my @ROUNDERS    = qw(ceil floor);
my @BOOLEANS    = qw(false true);
my @BUNDLE      = qw(ceil false floor true);

# The table holds the names that a mutator may write in place of another, with the modules that define them.
# CORE stands for Perl itself.
my %PROVIDED = (
    'CORE'            => [qw(index lc lcfirst pop push rindex shift uc ucfirst unshift)],
    'List::Util'      => \@REDUCERS,
    'List::MoreUtils' => \@QUANTIFIERS,
    'List::SomeUtils' => \@QUANTIFIERS,
    'List::AllUtils'  => \@REDUCERS,
    'POSIX'           => \@ROUNDERS,
    'builtin'         => \@BUNDLE,
    'boolean'         => \@BOOLEANS,
);

# A tag in the list of a use statement stands for these names, and :DEFAULT is the tag of a statement without a list.
my %TAGGED = (
    'List::MoreUtils' => { ':all'     => \@QUANTIFIERS },
    'List::SomeUtils' => { ':all'     => \@QUANTIFIERS },
    'List::AllUtils'  => { ':all'     => \@REDUCERS },
    'POSIX'           => { ':DEFAULT' => \@ROUNDERS, ':math_h' => \@ROUNDERS },
    'builtin'         => { ':5.40'    => \@BUNDLE,   ':5.42'   => \@BUNDLE, ':5.44' => \@BUNDLE },
    'boolean'         => { ':DEFAULT' => \@BOOLEANS, ':all'    => \@BOOLEANS },
);

signature_for provides => ( positional => [ Str, Str ], returns => Bool );

sub provides ( $module, $name ) {
    return _provided( $module, $name );
}

signature_for is_core => ( positional => [Str], returns => Bool );

sub is_core ($name) {
    return _provided( 'CORE', $name );
}

sub _provided ( $module, $name ) {
    return ( grep { $_ eq $name } @{ $PROVIDED{$module} || [] } ) ? 1 : 0;
}

signature_for listed => ( positional => [ Str, Str ], returns => ArrayRef [Str] );

sub listed ( $module, $item ) {
    return [$item] if $item =~ /\A[^\W\d]\w*\z/;
    return _tagged( $module, $item );
}

signature_for default_exports => ( positional => [Str], returns => ArrayRef [Str] );

sub default_exports ($module) {
    return _tagged( $module, ':DEFAULT' );
}

sub _tagged ( $module, $tag ) {
    return [ @{ ( $TAGGED{$module} || {} )->{$tag} || [] } ];
}

1;

__END__

=head1 NAME

Test::Mutation::Mutator::Providers - the modules that define the names a mutator may write

=head1 SYNOPSIS

    my $written = Test::Mutation::Mutator::Providers::provides( 'List::Util', 'all' ) ? 'List::Util::all' : undef;

=head1 DESCRIPTION

A mutator that replaces one function with another writes a name, and the file must resolve that name.
The table is a fixed part of the tool, so the mutants of a file depend on its text alone and never on the modules of one machine.

=head1 FUNCTIONS

=head2 provides

True when the module defines a subroutine of the name.
The module C<CORE> stands for Perl itself.

=head2 is_core

True when the name is a function of Perl itself.

=head2 listed

Returns the names that one item in the list of a C<use> statement imports from the module.
A name stands for itself, a tag of the table stands for its names, and another text stands for nothing.

=head2 default_exports

Returns the names that a C<use> statement without a list imports from the module, among the names of the table.

=cut
