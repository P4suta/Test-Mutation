use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/lib';
use Gate;
use Library;
use TypeContractGate;

# Every public subroutine declares a checked signature with a return type, and every attribute declares a type.

subtest 'the gate rejects missing contracts' => sub {
    is TypeContractGate::violations("sub area (\$w, \$h) { return \$w * \$h }\n"),
      ['area has no signature_for declaration'], 'a public subroutine without a signature';
    is TypeContractGate::violations(
        "signature_for area => ( positional => [ Num, Num ] );\nsub area (\$w, \$h) { return \$w * \$h }\n"),
      ['the signature_for declaration of area has no returns type'], 'a signature without a return type';
    is TypeContractGate::violations("has width => ( is => 'ro', required => 1 );\n"),
      ['the attribute width has no isa type'],
      'an attribute without a type';
};

subtest 'the gate accepts complete contracts and private helpers' => sub {
    my $code = <<'PERL';
has width => ( is => 'ro', isa => Num, required => 1 );
signature_for area => ( method => 1, positional => [], returns => Num );
sub area ($self) { return $self->width * 2 }
sub _helper ($x) { return $x }
sub BUILD ($self, $args) { return }
PERL
    is TypeContractGate::violations($code), [], 'no violation';
};

subtest 'the gate rejects a type without a shape' => sub {
    is TypeContractGate::loose_types("has facts => ( is => 'ro', isa => HashRef, default => sub { {} } );\n"),
      ['1 bare HashRef'], 'a hash that names no type for its values';
    is TypeContractGate::loose_types(
        "signature_for f => ( positional => [ ArrayRef, HashRef [Str] ], returns => ArrayRef );\n"),
      ['2 bare ArrayRef'], 'an array that names no type for its elements, as an argument and as the result';
    is TypeContractGate::loose_types("my \$TASK = Dict [ command => ArrayRef [Str], payload => Optional [Any] ];\n"),
      ['1 Any'], 'a value of any type, in a type that the file defines for its signatures';
    is TypeContractGate::loose_types(
        "has a => ( is => 'ro', isa => HashRef );\nhas b => ( is => 'ro', isa => Any );\n"),
      [ '1 Any', '1 bare HashRef' ], 'each loose type has its count';

    my $shaped = <<'PERL';
use Types::Standard qw(Any ArrayRef HashRef Int Str);
has names => ( is => 'ro', isa => ArrayRef [Str], required => 1 );
signature_for f => ( positional => [ HashRef [ ArrayRef [Int] ] ], returns => Int );
my %count = ( HashRef => 1, Any => 2 );
my $one   = $count{ArrayRef};
PERL
    is TypeContractGate::loose_types($shaped), [], 'an import, types with elements, and a key with the name of a type';
};

subtest 'the gate counts the contracts it reads' => sub {
    my $code = <<'PERL';
has width  => ( is => 'ro', isa => Num, required => 1 );
has height => ( is => 'ro', isa => Num, required => 1 );
signature_for area => ( method => 1, positional => [], returns => Num );
sub area ($self) { return $self->width * $self->height }
sub _helper ($x) { return $x }
PERL
    is TypeContractGate::counts($code), { attributes => 2, signatures => 1 }, 'two attributes and one signature';
    is TypeContractGate::counts("sub _helper (\$x) { return \$x }\n"), { attributes => 0, signatures => 0 },
      'a private helper declares nothing';
};

# The shim runs on Perl 5.10 with core modules alone, so it declares no signature.
my @files = grep { $_ ne 'lib/Test/Mutation/Shim.pm' } Library::modules()->@*;
Gate::checked( 'library files', scalar @files, at_least => 31 );
my %total = ( attributes => 0, signatures => 0 );
my @loose;
for my $file (@files) {
    open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
    my $code = do { local $/ = undef; readline $handle };
    close $handle or die "close $file: $!";
    is TypeContractGate::violations($code), [], "$file declares its contracts";
    push @loose, map { "$file uses $_" } TypeContractGate::loose_types($code)->@*;
    my $counts = TypeContractGate::counts($code);
    $total{$_} += $counts->{$_} for keys %total;
}
Gate::findings( 'type-contracts', \@loose );
Gate::checked( 'signatures', $total{signatures}, at_least => 65 );
Gate::checked( 'attributes', $total{attributes}, at_least => 70 );

done_testing;
