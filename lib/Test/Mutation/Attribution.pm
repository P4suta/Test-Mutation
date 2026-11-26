package Test::Mutation::Attribution;
use v5.36;
use Types::Standard qw(Bool Enum Int Maybe Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

signature_for compilation => (
    positional => [ Bool, Bool, Str, Str, Maybe [Int], { default => undef } ],
    returns    => Enum [qw(ok parse compile-phase standalone)],
);

sub compilation ( $original, $passed, $diagnostic, $file, $begin_end ) {
    return 'standalone' unless $original;
    return 'ok'            if $passed;
    return 'compile-phase' if $diagnostic =~ /^(?:BEGIN|UNITCHECK|CHECK) [ ] failed--/mx;
    my $bareword = qr{\A Bareword [ ] "[^"\n]+" [ ] not [ ] allowed}x;
    if ( defined $begin_end && $diagnostic =~ /$bareword [^\n]*? at [ ] \Q$file\E [ ] line [ ] ([0-9]+)/x ) {
        return 'compile-phase' if $1 > $begin_end;
    }
    return 'parse' if $diagnostic =~ /^\Q$file\E [ ] had [ ] compilation [ ] errors[.]$/mx;
    return 'parse' if $diagnostic =~ /\bat [ ] \Q$file\E [ ] line [ ] [0-9]+/x;
    return 'compile-phase';
}

1;

__END__

=head1 NAME

Test::Mutation::Attribution - identify what prevented Perl from compiling a changed file

=head1 FUNCTIONS

=head2 compilation

Returns C<standalone> when the original requires its normal application context.
A successful check of the changed file returns C<ok>.
Perl diagnostics that reject the changed source return C<parse>.
An exception from a compilation block or a process that stops during compilation returns C<compile-phase>.

=cut
