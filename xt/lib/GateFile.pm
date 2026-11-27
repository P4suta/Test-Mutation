package GateFile;
use v5.36;
use PPI;

sub _names_a_rejection ($word) {
    my $name = $word->snext_sibling;
    return $name && $name->isa('PPI::Token::Quote') && $name->string =~ /\breject/ ? 1 : 0;
}

# Code tokens alone count, so a comment or a string that mentions a count states nothing.
sub violations ($code) {
    my $document = PPI::Document->new( \$code ) or die "the gate file does not parse\n";
    my @words    = @{ $document->find('PPI::Token::Word') || [] };
    my $counts   = grep { $_->content eq 'Gate::checked' } @words;
    my $rejects  = grep { $_->content eq 'subtest' && _names_a_rejection($_) } @words;
    return [ ( $counts ? () : 'states no count' ), ( $rejects ? () : 'has no rejecting subtest' ) ];
}

1;
