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

# The shim runs on Perl 5.10 with core modules alone, so it declares no signature.
my @files = grep { $_ ne 'lib/Test/Mutation/Shim.pm' } Library::modules()->@*;
Gate::checked( 'library files', scalar @files, at_least => 31 );
for my $file (@files) {
    open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
    my $code = do { local $/ = undef; readline $handle };
    close $handle or die "close $file: $!";
    is TypeContractGate::violations($code), [], "$file declares its contracts";
}

done_testing;
