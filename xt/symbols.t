use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/lib';
use DocumentedSymbols;
use Gate;
use Library;

# The documentation names every public subroutine and attribute of a module, and nothing else.
# The gate reads the source text, because a subroutine that another package installs has no trace at run time.

my $module = <<'PERL';
package Example;
use Moo;
has width  => ( is => 'ro', isa => Int );
has _cache => ( is => 'lazy', isa => Int );
signature_for area => ( method => 1, positional => [], returns => Int );
sub area ($self) { return $self->width * 2 }
sub _helper ($x) { return $x }
sub BUILD ( $self, $args ) { return }
1;

__END__

=head1 NAME

Example - a shape

=head1 SYNOPSIS

    my $shape = Example->new( width => 2 );
    say $shape->area;

=head1 ATTRIBUTES

=head2 width

The width.

=head1 METHODS

=head2 area

Returns the area.

=cut
PERL

sub violations ( $code, @known ) {
    my $surface = DocumentedSymbols::surface($code);
    return DocumentedSymbols::violations( $surface, { map { $_ => 1 } $surface->{symbols}->@*, @known } );
}

subtest 'the gate accepts a module whose documentation matches its symbols' => sub {
    is DocumentedSymbols::surface($module),
      { symbols => [qw(area width)], documented => [qw(area width)], called => [qw(area new)] },
      'the surface holds the public symbols, the entries, and the calls of the synopsis';
    is violations( $module, 'new' ), [], 'no violation';
    is violations(
        $module =~ s/^=head2 width$/=head2 width, area/mr =~ s/^=head2 area\n\nReturns the area[.]\n\n//mr, 'new'
      ),
      [], 'one entry may name several symbols';
};

subtest 'the gate rejects documentation that differs from the symbols' => sub {
    is violations( $module =~ s/^=head2 area\n\nReturns the area[.]\n\n//mr, 'new' ), ['area has no entry'],
      'a public subroutine without an entry';
    is violations( $module =~ s/^=head2 width\n\nThe width[.]\n\n//mr, 'new' ), ['width has no entry'],
      'a public attribute without an entry';
    is violations( $module =~ s/^=head2 area$/=head2 splice/mr, 'new' ),
      [ 'area has no entry', 'the entry splice names no symbol' ], 'an entry for a subroutine that is absent';
    is violations( $module =~ s/\$shape->area/\$shape->splice/r, 'new' ),
      ['the synopsis calls splice, which no module defines'], 'a synopsis that calls an absent method';
    is violations($module), ['the synopsis calls new, which no module defines'],
      'a method counts only when the library defines it';
};

subtest 'the surface follows the forms that the library uses' => sub {
    my $plain = "package Plain;\nsub import { return }\nsub run (\$arg) { return }\nBEGIN { }\n1;\n";
    is DocumentedSymbols::surface($plain)->{symbols}, [qw(import run)], 'a plain subroutine and import are public';
    my $several = "has [qw(first second)] => ( is => 'ro' );\n";
    like dies { DocumentedSymbols::surface($several) }, qr/\Aan attribute needs a literal name/,
      'an attribute without a literal name is refused';
    my $qualified =
      "1;\n__END__\n\n=head1 SYNOPSIS\n\n    Plain::run( a => 1 );\n    my \$x = Other->from_bytes(\$b);\n\n=cut\n";
    is DocumentedSymbols::surface($qualified)->{called}, [qw(from_bytes run)],
      'qualified calls and class methods count';
};

my @modules = Library::modules()->@*;
my %surface;
for my $file (@modules) {
    open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
    $surface{$file} = DocumentedSymbols::surface( do { local $/ = undef; readline $handle } );
    close $handle or die "close $file: $!";
}

# A synopsis also calls the constructor that Moo defines and the methods of the values it shows.
my %defined = map { $_ => 1 } 'new', map { $_->{symbols}->@* } values %surface;
my @found;
for my $file (@modules) {
    push @found, map { "$file: $_" } DocumentedSymbols::violations( $surface{$file}, \%defined )->@*;
}
is \@found, [], 'every module documents its public symbols and nothing else';

my $symbols = 0;
$symbols += scalar $_->{symbols}->@* for values %surface;
Gate::checked( 'modules',        scalar @modules,                                     at_least => 32 );
Gate::checked( 'public symbols', $symbols,                                            at_least => 150 );
Gate::checked( 'synopses',       scalar( grep { $_->{called}->@* } values %surface ), at_least => 20 );

done_testing;
