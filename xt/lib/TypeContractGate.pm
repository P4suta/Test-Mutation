package TypeContractGate;
use v5.36;
use PPI;

my %EXEMPT    = map { $_ => 1 } qw(BUILD BUILDARGS DEMOLISH);
my %CONTAINER = map { $_ => 1 } qw(ArrayRef HashRef);

sub _document ($code) {
    return PPI::Document->new( \$code, feature_mods => { signatures => 1 } ) || die "the code does not parse\n";
}

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

sub _public_subs ($document) {
    return grep {
        my $name = $_->name;
        defined $name && $name !~ /\A_/ && !$EXEMPT{$name} && !$_->isa('PPI::Statement::Scheduled')
    } @{ $document->find('PPI::Statement::Sub') || [] };
}

sub _declarations ( $document, $word ) {
    return grep {
        my ($first) = _first_words($_);
        defined $first && $first eq $word
    } @{ $document->find('PPI::Statement') || [] };
}

sub violations ($code) {
    my $document = _document($code);
    my ( %signature, @violations );
    for my $statement ( _declarations( $document, 'signature_for' ) ) {
        my ( undef, $declared ) = _first_words($statement);
        $signature{$declared} = _has_key( $statement, 'returns' ) ? 'complete' : 'partial' if defined $declared;
    }
    for my $statement ( _declarations( $document, 'has' ) ) {
        my ( undef, $declared ) = _first_words($statement);
        push @violations, "the attribute $declared has no isa type"
          if defined $declared && !_has_key( $statement, 'isa' );
    }
    for my $name ( map { $_->name } _public_subs($document) ) {
        push @violations,
           !$signature{$name}              ? "$name has no signature_for declaration"
          : $signature{$name} eq 'partial' ? "the signature_for declaration of $name has no returns type"
          :                                  ();
    }
    return \@violations;
}

# A container without the type of its elements and a value of any type name a type and check no shape.
# The types of a signature often stand in a variable of the file, so every use in the code counts.
sub loose_types ($code) {
    my %count;
    for my $word ( @{ _document($code)->find('PPI::Token::Word') || [] } ) {
        my $name = $word->content;
        next if !$CONTAINER{$name} && $name ne 'Any';
        my $next   = $word->snext_sibling;
        my $holder = $word->parent;
        $holder = $holder->parent if $holder->isa('PPI::Statement::Expression');
        next if $holder->isa('PPI::Structure::Subscript');
        next if $next             && $next->isa('PPI::Token::Operator') && $next->content eq '=>';
        next if $CONTAINER{$name} && $next                              && $next->isa('PPI::Structure::Constructor');
        $count{ $name eq 'Any' ? 'Any' : "bare $name" }++;
    }
    return [ map { "$count{$_} $_" } sort keys %count ];
}

sub counts ($code) {
    my $document   = _document($code);
    my @attributes = _declarations( $document, 'has' );
    my @signatures = _declarations( $document, 'signature_for' );
    return { attributes => scalar @attributes, signatures => scalar @signatures };
}

1;
