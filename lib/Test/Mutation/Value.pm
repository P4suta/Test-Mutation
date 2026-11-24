package Test::Mutation::Value;
use v5.36;
use Moo::Role;

our $VERSION = '0.001';

# Moo keeps the arguments that a class takes with the maker of its constructor, and offers no other reader.
# An attribute without an argument has an undefined name of its argument, and an argument of another name has that name.
around BUILDARGS => sub ( $build, $class, @arguments ) {
    my $given = $class->$build(@arguments);
    my $specs = Moo->_constructor_maker_for($class)->all_attribute_specs;    ## no critic (Subroutines::ProtectPrivateSubs)
    my %taken = map { $_ => 1 } grep { defined }
      map { exists $specs->{$_}{init_arg} ? $specs->{$_}{init_arg} : $_ } keys $specs->%*;
    my @unknown = sort grep { !$taken{$_} } keys $given->%*;
    return $given if !@unknown;

    # The catalog is itself a class with this role, so it loads when a class first needs a message.
    require Test::Mutation::Message;
    die Test::Mutation::Message::text_of( 'class-argument-unknown', class => $class, names => join q{, }, @unknown )
      . "\n";
};

1;

__END__

=head1 NAME

Test::Mutation::Value - the role of a value that refuses an argument it lacks

=head1 SYNOPSIS

    package Test::Mutation::Shape;
    use Moo;
    with 'Test::Mutation::Value';

=head1 DESCRIPTION

A class that composes the role dies when its constructor gets an argument that names none of its attributes.
The error is a defect of the code that builds the value, so its message comes from the catalog as an internal error.
Every class of the library composes the role, so a misspelt name fails where it is written.

=cut
