package Permutl::Syntax::PPI;
use v5.36;
use PPI;
use Scalar::Util    qw(refaddr);
use Types::Standard qw(ArrayRef Dict InstanceOf Int Maybe Str);
use Type::Params    qw(signature_for);
use Permutl::Site;

our $VERSION = '0.001';

my %CONDITIONAL  = map { $_ => 1 } qw(if unless while until);
my %MODIFIER     = map { $_ => 1 } qw(if unless while until for foreach);
my %LOOP_CONTROL = map { $_ => 1 } qw(last next);
my %DECLARATOR   = map { $_ => 1 } qw(sub method class role package field);
my %UNARY_AFTER  = map { $_ => 1 } qw(return and or not xor if unless while until for foreach x print say push unshift);
my %CODE_BLOCK_WORD =
  map { $_ => 1 }
  qw(do eval sub map grep first any all none notall try catch finally defer method ADJUST class role else continue
  BEGIN END INIT CHECK UNITCHECK);
my %UNDELETABLE_FIRST_WORD = map { $_ => 1 } qw(package class role field method use no);
my %NEVER_A_CALL =
  map { $_ => 1 }
  qw(my our local state sub package class role field method use no return do eval else elsif for foreach
  continue given when default try catch finally defer BEGIN END INIT CHECK UNITCHECK ADJUST
  __PACKAGE__ __FILE__ __LINE__ __SUB__ __CLASS__);

my $SUPPRESSION = Dict [ first => Int, last => Maybe [Int], names => Maybe [ ArrayRef [Str] ] ];

signature_for analyze => (
    positional => [ InstanceOf ['Permutl::Source'] ],
    returns    => Dict [
        sites        => ArrayRef [ InstanceOf ['Permutl::Site'] ],
        suppressions => ArrayRef [$SUPPRESSION],
        problem      => Maybe [Str],
    ],
);

sub analyze ($source) {
    my $text = $source->text;
    return _problem('the file has carriage returns') if $text =~ /\r/;

    my $copy     = $text;
    my $document = PPI::Document->new( \$copy );
    return _problem( 'PPI cannot parse the file: ' . ( PPI::Document->errstr // 'unknown error' ) ) if !$document;
    return _problem('PPI does not reproduce the file') if $document->serialize ne $text;

    $document->index_locations;
    my $context = { source => $source, text => $text, scopes => {}, sites => [] };
    _visit( $context, $document, 0 );
    my @sites = sort { $a->start <=> $b->start || $a->end <=> $b->end } $context->{sites}->@*;
    return { sites => \@sites, suppressions => _suppressions($document), problem => undef };
}

sub _problem ($message) {
    return { sites => [], suppressions => [], problem => $message };
}

sub _visit ( $context, $element, $excluded ) {
    if ( $element->isa('PPI::Token') ) {
        _token_site( $context, $element ) if !$excluded && $element->significant;
        return;
    }
    my $skip = $excluded || _excluded($element);
    _structure_sites( $context, $element ) if !$skip;
    _visit( $context, $_, $skip ) for $element->children;
    return;
}

sub _excluded ($node) {
    return 1
      if $node->isa('PPI::Statement::Include')
      || $node->isa('PPI::Statement::Package')
      || $node->isa('PPI::Statement::End')
      || $node->isa('PPI::Statement::Data');
    return 0 if !$node->isa('PPI::Statement');
    return scalar grep { $_->isa('PPI::Token::Symbol') && $_->content eq '$VERSION' } $node->schildren;
}

sub _offset ( $context, $token ) {
    my $location = $token->location or return;
    my $offset   = $context->{source}->offset_of( $location->[0], $location->[1] );
    my $content  = $token->content;
    return if substr( $context->{text}, $offset, length $content ) ne $content;
    return $offset;
}

sub _span ( $context, $first, $last ) {
    my $start = _offset( $context, $first );
    my $end   = _offset( $context, $last );
    return if !defined $start || !defined $end;
    return ( $start, $end + length $last->content );
}

sub _add ( $context, %site ) {
    $site{text} = substr $context->{text}, $site{start}, $site{end} - $site{start};
    push $context->{sites}->@*, Permutl::Site->new(%site);
    return;
}

sub _token_site ( $context, $token ) {
    my $kind =
        $token->isa('PPI::Token::Operator')        ? 'operator'
      : $token->isa('PPI::Token::Word')            ? 'word'
      : $token->isa('PPI::Token::Number::Version') ? undef
      : $token->isa('PPI::Token::Number')          ? 'number'
      : $token->isa('PPI::Token::Quote')           ? 'string'
      :                                              undef;
    return if !defined $kind;

    my ( $start, $end ) = _span( $context, $token, $token ) or return;
    my $scope = _scope( $context, $token ) or return;
    my ( $role, $detail ) =
        $kind eq 'operator' ? _operator_role($token)
      : $kind eq 'word'     ? ( _word_role($token), {} )
      :                       ( q{}, {} );
    return if $kind eq 'word' && $role eq q{};
    _add(
        $context,
        kind   => $kind,
        start  => $start,
        end    => $end,
        role   => $role,
        scope  => $scope,
        detail => $detail,
    );
    return;
}

sub _operator_role ($token) {
    my $content  = $token->content;
    my $previous = $token->sprevious_sibling;
    return ( 'update', {} ) if $content eq '++' || $content eq '--';

    if ( $content eq '=~' || $content eq '!~' ) {
        my $next = $token->snext_sibling;
        my $operand =
           !$next                                           ? 'dynamic'
          : $next->isa('PPI::Token::Regexp::Substitute')    ? 'substitute'
          : $next->isa('PPI::Token::Regexp::Transliterate') ? 'transliterate'
          :                                                   'match';
        return ( 'binary', { operand => $operand } );
    }

    my $unary =
         !$previous
      || ( $previous->isa('PPI::Token::Operator') && $previous->content ne '++' && $previous->content ne '--' )
      || ( $previous->isa('PPI::Token::Word') && $UNARY_AFTER{ $previous->content } );
    return ( 'unary',  {} ) if $unary && ( $content eq '-' || $content eq '+' );
    return ( 'unary',  {} ) if $content eq '!' || $content eq '~' || $content eq '\\' || $content eq 'not';
    return ( 'binary', {} );
}

sub _word_role ($token) {
    my $content  = $token->content;
    my $previous = $token->sprevious_sibling;
    my $next     = $token->snext_sibling;
    my $parent   = $token->parent;

    return q{} if _is_data_word( $previous, $next, $parent );

    my $leads = !$previous || $previous->isa('PPI::Token::Label');
    if ( $CONDITIONAL{$content} ) {
        return 'compound' if $leads && $parent->isa('PPI::Statement::Compound');
        return 'modifier' if !$leads;
        return q{};
    }
    return 'control' if $LOOP_CONTROL{$content} && $leads && $parent->isa('PPI::Statement::Break');
    return q{}       if $NEVER_A_CALL{$content} || $LOOP_CONTROL{$content};
    return 'call';
}

sub _is_operator ( $element, @contents ) {
    return 0 if !$element || !$element->isa('PPI::Token::Operator');
    return scalar grep { $element->content eq $_ } @contents;
}

sub _is_data_word ( $previous, $next, $parent ) {
    return 1 if _is_operator( $next, '=>', '->' ) || _is_operator( $previous, '->' );
    return 1 if $previous && $previous->isa('PPI::Token::Word') && $DECLARATOR{ $previous->content };
    return 0 if $previous || $next;
    return $parent->isa('PPI::Statement::Expression') && $parent->parent->isa('PPI::Structure::Subscript') ? 1 : 0;
}

sub _is_name ($element) {
    return $element->isa('PPI::Token::Word') || ( $element->isa('PPI::Token::Operator') && $element->content eq 'x' );
}

sub _is_code_block ($block) {
    my $parent = $block->parent;
    return 1
      if $parent->isa('PPI::Statement::Compound')
      || $parent->isa('PPI::Statement::Sub')
      || $parent->isa('PPI::Statement::Scheduled');
    my $previous = $block->sprevious_sibling;
    return 1 if !$previous;
    return 1 if $previous->isa('PPI::Structure::List') || $previous->isa('PPI::Structure::Signature');
    return 0 if !_is_name($previous);
    return 1 if $CODE_BLOCK_WORD{ $previous->content };
    my $before = $previous->sprevious_sibling;
    return $before && $before->isa('PPI::Token::Word') && $DECLARATOR{ $before->content } ? 1 : 0;
}

sub _running_statement ($element) {
    my $statement = $element->isa('PPI::Statement') ? $element : $element->statement;
    while ($statement) {
        my $parent = $statement->parent or return $statement;
        return $statement if $parent->isa('PPI::Document');
        return $statement
          if ref $statement ne 'PPI::Statement::Expression'
          && $parent->isa('PPI::Structure::Block')
          && _is_code_block($parent);
        $statement = $parent->statement or return;
    }
    return;
}

sub _scope ( $context, $element ) {
    my $statement = _running_statement($element) or return;
    my $key       = refaddr $statement;
    if ( !exists $context->{scopes}{$key} ) {
        my $first = $statement->first_token->location;
        my $last  = $statement->last_token->location;
        $context->{scopes}{$key} = $first && $last ? [ $first->[0], $last->[0] ] : undef;
    }
    return $context->{scopes}{$key};
}

sub _structure_sites ( $context, $node ) {
    _condition_site( $context, $node ) if $node->isa('PPI::Structure::Condition');
    return                             if !$node->isa('PPI::Statement');
    _sub_body_sites( $context, $node );
    _return_site( $context, $node )    if $node->isa('PPI::Statement::Break');
    _statement_site( $context, $node ) if ref $node eq 'PPI::Statement';
    return;
}

sub _inner_span ( $context, $structure ) {
    my $open  = $structure->start  or return;
    my $close = $structure->finish or return;
    return if !$structure->schildren;
    my $start = _offset( $context, $open );
    my $end   = _offset( $context, $close );
    return if !defined $start || !defined $end;
    return ( $start + 1, $end );
}

sub _condition_site ( $context, $condition ) {
    my ( $start, $end ) = _inner_span( $context, $condition ) or return;
    my $scope   = _scope( $context, $condition ) or return;
    my $keyword = $condition->sprevious_sibling;
    _add(
        $context,
        kind   => 'condition',
        start  => $start,
        end    => $end,
        scope  => $scope,
        detail => { keyword => $keyword ? $keyword->content : q{} },
    );
    return;
}

sub _sub_body_sites ( $context, $statement ) {
    my @bodies;
    if ( $statement->isa('PPI::Statement::Sub') && !$statement->isa('PPI::Statement::Scheduled') ) {
        my $block = $statement->block;
        push @bodies, [ $block, $statement->name // q{} ] if $block;
    }
    else {
        my @children = $statement->schildren;
        for my $index ( 0 .. $#children ) {
            my $child = $children[$index];
            next if !$child->isa('PPI::Token::Word') || $child->content ne 'method';
            my $name = $children[ $index + 1 ];
            next if !$name || !_is_name($name);
            my ($block) = grep { $_->isa('PPI::Structure::Block') } @children[ $index + 2 .. $#children ];
            push @bodies, [ $block, $name->content, $child ] if $block;
        }
    }

    for my $body (@bodies) {
        my ( $block, $name, $head ) = $body->@*;
        my ( $start, $end ) = _inner_span( $context, $block ) or next;
        my $first = ( $head // $statement->first_token )->location or next;
        my $last  = $block->finish->location                       or next;
        _add(
            $context,
            kind   => 'sub_body',
            start  => $start,
            end    => $end,
            scope  => [ $first->[0], $last->[0] ],
            detail => { name => $name },
        );
    }
    return;
}

sub _return_site ( $context, $statement ) {
    my ( $keyword, @rest ) = $statement->schildren;
    return if !$keyword || !$keyword->isa('PPI::Token::Word') || $keyword->content ne 'return';

    my @expression;
    for my $child (@rest) {
        last if $child->isa('PPI::Token::Structure') && $child->content eq q{;};
        last if $child->isa('PPI::Token::Word')      && $MODIFIER{ $child->content };
        push @expression, $child;
    }
    return if !@expression;

    my $first = $expression[0]->isa('PPI::Token')  ? $expression[0]  : $expression[0]->first_token;
    my $last  = $expression[-1]->isa('PPI::Token') ? $expression[-1] : $expression[-1]->last_token;
    my ( $start, $end ) = _span( $context, $first, $last ) or return;
    my $scope = _scope( $context, $statement ) or return;
    my $literal =
      @expression == 1 && $expression[0]->isa('PPI::Token::Number') ? $expression[0]->content : undef;
    _add(
        $context,
        kind   => 'return',
        start  => $start,
        end    => $end,
        scope  => $scope,
        detail => { defined $literal ? ( literal => $literal ) : () },
    );
    return;
}

sub _statement_site ( $context, $statement ) {
    my $parent = $statement->parent;
    return if !$parent->isa('PPI::Document') && !( $parent->isa('PPI::Structure::Block') && _is_code_block($parent) );

    my @children = $statement->schildren;
    return if !@children;
    return if grep { $_->isa('PPI::Structure::Block') } @children;
    return if $children[0]->isa('PPI::Token::Word') && $UNDELETABLE_FIRST_WORD{ $children[0]->content };

    my @content = grep { !( $_->isa('PPI::Token::Structure') && $_->content eq q{;} ) } @children;
    return if !@content;
    return if @content == 1 && ( $content[0]->isa('PPI::Token::Number') || $content[0]->isa('PPI::Token::Quote') );

    my $first = $statement->first_token;
    my $last  = $statement->last_token;
    my ( $start, $end ) = _span( $context, $first, $last ) or return;
    my $scope = _scope( $context, $statement ) or return;
    _add(
        $context,
        kind  => 'statement',
        start => $start,
        end   => $end,
        scope => $scope,
    );
    return;
}

sub _suppressions ($document) {
    my $comments = $document->find('PPI::Token::Comment') || [];
    my @ranges;
    my $open;
    for my $comment ( $comments->@* ) {
        my ( $verb, $list ) = $comment->content =~ /\A\s*[#][#]\s*(no|use)\s+mutate\b\s*(?:[(]([^)]*)[)])?/x;
        next if !defined $verb;
        my $line  = $comment->location->[0];
        my $names = defined $list ? [ grep { length } split /[\s,]+/, $list ] : undef;
        if ( $verb eq 'use' ) {
            $open->{last} = $line if $open;
            $open = undef;
        }
        elsif ( $comment->line ) {
            $open = { first => $line, last => undef, names => $names };
            push @ranges, $open;
        }
        else {
            push @ranges, { first => $line, last => $line, names => $names };
        }
    }
    return \@ranges;
}

1;

__END__

=head1 NAME

Permutl::Syntax::PPI - find mutation sites with PPI

=head1 SYNOPSIS

    my $analysis = Permutl::Syntax::PPI::analyze($source);
    die $analysis->{problem} if defined $analysis->{problem};
    my @sites = $analysis->{sites}->@*;

=head1 DESCRIPTION

The module parses a source with PPI and reports the places a mutator can change.
It verifies that every reported span holds the text PPI attributes to it, and it drops a span that fails the check.
C<use>, C<no>, and C<package> statements, C<$VERSION> assignments, and text after C<__END__> produce no sites.

=head1 FUNCTIONS

=head2 analyze

Returns a hash reference with three keys.
C<sites> holds L<Permutl::Site> objects in source order.
C<suppressions> holds the line ranges that C<## no mutate> comments cover.
C<problem> names the reason when the file cannot be analyzed.

=cut
