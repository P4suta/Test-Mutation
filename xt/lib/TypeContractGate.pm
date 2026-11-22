package TypeContractGate;
use v5.36;
use PPI;

my %EXEMPT = map { $_ => 1 } qw(BUILD BUILDARGS DEMOLISH);

sub _first_words ($statement) {
    return map { $_->content } grep { $_->isa('PPI::Token::Word') } $statement->schildren;
}

sub _has_key ( $statement, $key ) {
    my $words = $statement->find( sub { $_[1]->isa('PPI::Token::Word') && $_[1]->content eq $key } );
    return scalar grep {
        my $next = $_->snext_sibling;
        $next && $next->isa('PPI::Token::Operator') && $next->content eq '=>'
    } @{ $words || [] };
}

sub violations ($code) {
    my $document = PPI::Document->new( \$code, feature_mods => { signatures => 1 } ) or die 'the code does not parse';
    my ( %signature, @violations );

    for my $statement ( @{ $document->find('PPI::Statement') || [] } ) {
        my ( $first, $second ) = _first_words($statement);
        next if !defined $first || !defined $second;
        if ( $first eq 'signature_for' ) {
            $signature{$second} = _has_key( $statement, 'returns' ) ? 'complete' : 'partial';
        }
        elsif ( $first eq 'has' && !_has_key( $statement, 'isa' ) ) {
            push @violations, "the attribute $second has no isa type";
        }
    }

    for my $sub ( @{ $document->find('PPI::Statement::Sub') || [] } ) {
        my $name = $sub->name;
        next if !defined $name || $name =~ /\A_/ || $EXEMPT{$name} || $sub->isa('PPI::Statement::Scheduled');
        push @violations,
           !$signature{$name}              ? "$name has no signature_for declaration"
          : $signature{$name} eq 'partial' ? "the signature_for declaration of $name has no returns type"
          :                                  ();
    }
    return \@violations;
}

1;
