package DocumentedSymbols;
use v5.36;
use PPI;

my %CALLED_BY_MOO = map { $_ => 1 } qw(BUILD BUILDARGS DEMOLISH);

sub _unique (@names) {
    my %seen;
    return [ sort grep { !$seen{$_}++ } @names ];
}

sub _attribute ($statement) {
    my ( $has, $name ) = $statement->schildren;
    return                if !$has->isa('PPI::Token::Word') || $has->content ne 'has';
    return $name->content if $name && $name->isa('PPI::Token::Word');
    return $name->string  if $name && $name->isa('PPI::Token::Quote') && $name->can('string');
    die "an attribute needs a literal name\n";
}

sub _symbols ($document) {
    my @subs = grep { !$_->isa('PPI::Statement::Scheduled') } @{ $document->find('PPI::Statement::Sub') || [] };
    my @names =
      ( ( map { $_->name } @subs ), map { _attribute($_) } @{ $document->find('PPI::Statement') || [] } );
    return grep { defined && !/\A_/ && !$CALLED_BY_MOO{$_} } @names;
}

sub _synopsis ($code) {
    my ($text) = $code =~ /^=head1 SYNOPSIS\n(.*?)^=(?:head1|cut)\b/ms;
    return defined $text ? $text : q{};
}

# The surface comes from the source text alone: the named subroutines, the attributes, the entries, and the calls.
sub surface ($code) {
    my $document = PPI::Document->new( \$code, feature_mods => { signatures => 1 } )
      or die "the module does not parse\n";
    my $synopsis = _synopsis($code);
    return {
        symbols    => _unique( _symbols($document) ),
        documented => _unique( map { split /,\s*/ } $code =~ /^=head2 (.+)$/mg ),
        called     => _unique( $synopsis =~ /->\s*([[:alpha:]_]\w*)/g, $synopsis =~ /\b\w+(?:::\w+)*::(\w+)\s*[(]/g ),
    };
}

sub violations ( $surface, $defined ) {
    my %symbol     = map { $_ => 1 } $surface->{symbols}->@*;
    my %documented = map { $_ => 1 } $surface->{documented}->@*;
    return [
        ( map { "$_ has no entry" } grep { !$documented{$_} } $surface->{symbols}->@* ),
        ( map { "the entry $_ names no symbol" } grep { !$symbol{$_} } $surface->{documented}->@* ),
        (
            map  { "the synopsis calls $_, which no module defines" }
            grep { !$defined->{$_} } $surface->{called}->@*
        ),
    ];
}

1;
