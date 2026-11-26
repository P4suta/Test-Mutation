package Test::Mutation::Build;
use v5.36;
use Config          qw(%Config);
use Time::HiRes     ();
use Types::Standard qw(ArrayRef Bool CodeRef Dict Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Project;

our $VERSION = '0.001';

my $NATIVE = Dict [ sources => ArrayRef [Str], objects => ArrayRef [Str] ];

signature_for native => ( positional => [Str], returns => $NATIVE );

sub native ($root) {
    return {
        sources => Test::Mutation::Project::files( $root, ['**/*.xs'],                       [] ),
        objects => Test::Mutation::Project::files( $root, ["blib/arch/**/*.$Config{dlext}"], [] ),
    };
}

signature_for prepare => (
    named => [
        root      => Str,
        perl      => Str,
        native    => $NATIVE,
        libraries => ArrayRef [Str],
        targets   => ArrayRef [Str],
        in_place  => Bool,
        run       => CodeRef
    ],
    returns => ArrayRef [Str],
);

sub prepare ($arg) {
    my $root   = $arg->root;
    my $native = $arg->native;
    my $wants_build =
         $native->{sources}->@*
      || $native->{objects}->@*
      || grep { m{(?:\A|/)blib/(?:lib|arch)/?\z} } $arg->libraries->@*;
    return [] unless $wants_build;
    my $recipe = -f "$root/Makefile.PL" ? 'Makefile.PL' : -f "$root/Build.PL" ? 'Build.PL' : undef;
    Test::Mutation::Error::raise('build-recipe-missing') if !defined $recipe && $native->{sources}->@*;
    my @command = defined $recipe && $recipe eq 'Build.PL' ? ( $arg->perl, 'Build' ) : ( $Config{make} );
    return _check_products( $arg, \@command ) if $arg->in_place;
    return [] unless defined $recipe;
    $arg->run->( $root, [ $arg->perl, $recipe ] );

    if ( $recipe eq 'Makefile.PL' && -f "$root/Makefile" ) {
        my $input = ( stat "$root/$recipe" )[9];
        my $made  = ( stat "$root/Makefile" )[9];
        if ( $made <= $input && !-l "$root/$recipe" ) {
            my $older = $made - 1;
            Time::HiRes::utime( $older, $older, "$root/$recipe" )
              or Test::Mutation::Error::raise( 'file-unwritable', path => $recipe, reason => "$!" );
        }
    }
    $arg->run->( $root, \@command );
    return \@command;
}

sub _check_products ( $arg, $command ) {
    my $root     = $arg->root;
    my @products = $arg->native->{objects}->@*;
    for my $xs ( $arg->native->{sources}->@* ) {
        my $time       = ( Time::HiRes::stat("$root/$xs") )[9];
        my ($stem)     = $xs =~ m{([^/]+)[.]xs\z};
        my @named      = grep { m{(?:\A|/)\Q$stem.$Config{dlext}\E\z} } @products;
        my @candidates = @named ? @named : @products;
        my $current    = grep { ( Time::HiRes::stat("$root/$_") )[9] >= $time } @candidates;
        _stale( $xs, $command ) if !$current;
    }
    for my $source ( $arg->targets->@* ) {
        my $copy = "blib/$source";
        next unless $source =~ m{\Alib/} && -f "$root/$copy";
        _stale( $copy, $command )
          if ( Time::HiRes::stat("$root/$copy") )[9] < ( Time::HiRes::stat("$root/$source") )[9];
    }
    return [];
}

sub _stale ( $file, $command ) {
    return Test::Mutation::Error::raise( 'build-product-stale', path => $file, command => join( q{ }, @$command ) );
}

1;

__END__

=head1 NAME

Test::Mutation::Build - prepare the Perl distribution that a test loads

=head1 FUNCTIONS

=head2 native

Lists XS sources and shared objects in the distribution's architecture library.

=head2 prepare

Configures and builds the distribution in a private copy and returns its incremental build command.
In-place measurement checks the ages of existing build products.

=cut
