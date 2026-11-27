package Test::Mutation::CompilerInputs;
use 5.010;
use strict;
use warnings;
use Cwd ();

our $VERSION = '0.001';

my ($record) = ( $ENV{TEST_MUTATION_COMPILER_INPUTS} || q{} ) =~ /\A(.*)\z/s;
my %initial  = map { _absolute($_) => 1 } grep { !ref } @INC;
my $operands = $ENV{TEST_MUTATION_COMPILER_READS} || q{};

sub _absolute {
    my ($path) = @_;
    return $path =~ m{\A/} ? $path : Cwd::getcwd() . ( $path eq q{.} ? q{} : "/$path" );
}

sub _opened {
    my ( $paths, $environment ) = @_;
    for my $operand ( split /,/, $operands ) {
        return unless $operand =~ /\A([ef])((?:[a-f0-9]{2})+)\z/;
        my ( $kind, $name ) = ( $1, pack 'H*', $2 );
        my $path = $kind eq 'e' ? $environment->{$name} : $name;
        return unless defined $path && length $path && -f $path;
        $paths->{ _absolute($path) } = 1;
    }
    return 1;
}

sub _record {
    return unless length $record;
    my %paths     = map { $_ => 1 } grep { !$initial{$_} } map { _absolute($_) } grep { !ref } @INC;
    my @libraries = ( keys %initial, keys %paths );
    return unless _opened( \%paths, \%ENV );
    for my $loaded ( values %INC ) {
        next unless defined $loaded;
        return if ref $loaded;
        my $file = _absolute($loaded);
        next if grep { index( $file, "$_/" ) == 0 } @libraries;
        return unless -f $file;
        $paths{$file} = 1;
    }
    open my $out, '>:raw', $record or return;
    print {$out} map { unpack( 'H*', $_ ) . "\n" } sort keys %paths or return;
    print {$out} ".\n"                                              or return;
    close $out;
    return;
}

CHECK { _record() }

1;

__END__

=head1 NAME

Test::Mutation::CompilerInputs - record external inputs to a standalone Perl compilation

=head1 DESCRIPTION

The driver loads this module in the target Perl before a standalone compilation.
The module records additional library directories and modules loaded outside the initial search path.
For known read-only C<open> calls, the target interpreter resolves literal paths and named environment variables.

=cut
