package Permutl::Syntax::PPI;
use v5.36;
use PPI;
use PPIx::Regexp;
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
my %UNDELETABLE_FIRST_WORD =
  map { $_ => 1 } qw(package class role field method use no my our local state return last next redo goto);
my %OPEN_BLOCK_HEAD  = map { $_ => 1 } qw(ADJUST if unless while until for foreach);
my %BLOCK_FIRST_HEAD = map { $_ => 1 } qw(finally defer try);
my %NAMED_BLOCK_HEAD = map { $_ => 1 } qw(class role method sub);
my %CONTINUATION     = map { $_ => 1 } qw(elsif else continue catch finally);
my %BODY_HEAD        = map { $_ => 1 } qw(method sub ADJUST);
my %EXCLUDED_HEAD    = map { $_ => 1 } qw(use no package);
my %NEVER_A_CALL =
  map { $_ => 1 }
  qw(my our local state sub package class role field method use no return do eval else elsif for foreach
  continue given when default try catch finally defer BEGIN END INIT CHECK UNITCHECK ADJUST
  __PACKAGE__ __FILE__ __LINE__ __SUB__ __CLASS__);

my @REGEX_TOKEN = qw(PPI::Token::Regexp::Match PPI::Token::Regexp::Substitute PPI::Token::QuoteLike::Regexp);
my %REGEX_ROLE  = (
    'PPIx::Regexp::Token::Assertion'  => 'anchor',
    'PPIx::Regexp::Token::Quantifier' => 'quantifier',
    'PPIx::Regexp::Token::Modifier'   => 'flag',
);
my %ANCHOR = map { $_ => 1 } ( q{^}, q{$}, '\\A', '\\z', '\\Z' );

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
    return _visit_segments( $context, $element, $excluded ) if ref $element eq 'PPI::Statement';
    my $skip = $excluded || _excluded($element);
    _structure_sites( $context, $element ) if !$skip;
    _visit( $context, $_, $skip ) for $element->children;
    return;
}

sub _visit_segments ( $context, $statement, $excluded ) {
    my $parent = $statement->parent;
    my $runs =
      $parent->isa('PPI::Document') || ( $parent->isa('PPI::Structure::Block') && _is_code_block( $context, $parent ) );
    for my $segment ( _segments( $context, $statement )->@* ) {
        my @children = $segment->{children}->@*;
        my $skip     = $excluded || _is_word( $children[0], \%EXCLUDED_HEAD ) || _holds_version(@children);
        if ( !$skip ) {
            _body_site( $context, $segment );
            _return_site( $context, _segment_scope($segment), @children );
            _statement_site( $context, $segment ) if $runs;
        }
        my %header = map { refaddr($_) => 1 } _header($segment);
        _visit( $context, $_, $skip || $header{ refaddr $_ } ) for @children;
    }
    return;
}

# The name, the version, and the attributes of a declaration hold no behavior to change.
sub _header ($segment) {
    my ( $head, @rest ) = $segment->{children}->@*;
    if ( $segment->{closes} && _is_word( $head, \%NAMED_BLOCK_HEAD ) ) {
        return grep { !$_->isa('PPI::Structure::Block') } @rest
          if $head->content eq 'class' || $head->content eq 'role';
        my @header;
        for my $child (@rest) {
            last if $child->isa('PPI::Structure');
            push @header, $child;
        }
        return @header;
    }
    return if !_is_word( $head, { field => 1 } );
    my @attributes;
    for my $child ( @rest[ 1 .. $#rest ] ) {
        last if _is_semicolon($child) || _is_operator( $child, q{=}, '//=', '||=' );
        push @attributes, $child;
    }
    return @attributes;
}

sub _is_word ( $element, $words ) {
    return $element && $element->isa('PPI::Token::Word') && $words->{ $element->content } ? 1 : 0;
}

sub _is_semicolon ($element) {
    return $element->isa('PPI::Token::Structure') && $element->content eq q{;} ? 1 : 0;
}

sub _ends_at_block ( $head, $next, $after ) {
    return 0                                           if !$next;
    return 1                                           if _is_word( $head,  \%OPEN_BLOCK_HEAD );
    return $next->isa('PPI::Structure::Block') ? 1 : 0 if _is_word( $head,  \%BLOCK_FIRST_HEAD );
    return 0                                           if !_is_word( $head, \%NAMED_BLOCK_HEAD );

    # PPI reads a name before an attribute, as in "method name :lvalue", as a label.
    return 1 if $next->isa('PPI::Token::Label');
    return _is_name($next) && !_is_operator( $after, '=>', q{,} ) ? 1 : 0;
}

# PPI ends a statement it does not know, such as a method or a defer block, at the next semicolon.
sub _segments ( $context, $statement ) {
    my $key = refaddr $statement;
    return $context->{segments}{$key} if $context->{segments}{$key};
    my @children = $statement->schildren;
    my @segments;
    while (@children) {
        my @part = shift @children;
        my ( $next, $after ) = @children;
        my $closes = _ends_at_block( $part[0], $next, $after );
        while (@children) {
            push @part, shift @children;
            last if _is_semicolon( $part[-1] );
            last if $closes && $part[-1]->isa('PPI::Structure::Block') && !_is_word( $children[0], \%CONTINUATION );
        }
        my $segment = { children => \@part, closes => $closes };
        $context->{segment_of}{ refaddr $_ } = $segment for @part;
        push @segments, $segment;
    }
    return $context->{segments}{$key} = \@segments;
}

sub _segment_of ( $context, $statement, $element ) {
    _segments( $context, $statement );
    my $child = $element;
    while ( my $parent = $child->parent ) {
        return $context->{segment_of}{ refaddr $child } if refaddr($parent) == refaddr $statement;
        $child = $parent;
    }
    return;
}

sub _segment_scope ($segment) {
    if ( !exists $segment->{scope} ) {
        my ( $first, $last ) = map { $_->location } _edge_tokens( $segment->{children}->@[ 0, -1 ] );
        $segment->{scope} = $first && $last ? [ $first->[0], $last->[0] ] : undef;
    }
    return $segment->{scope};
}

sub _edge_tokens ( $first, $last ) {
    return (
        $first->isa('PPI::Token') ? $first : $first->first_token,
        $last->isa('PPI::Token')  ? $last  : $last->last_token
    );
}

sub _excluded ($node) {
    return 1
      if $node->isa('PPI::Statement::Include')
      || $node->isa('PPI::Statement::Package')
      || $node->isa('PPI::Statement::End')
      || $node->isa('PPI::Statement::Data');
    return 0 if !$node->isa('PPI::Statement');
    return _holds_version( $node->schildren );
}

sub _holds_version (@children) {
    return scalar grep { $_->isa('PPI::Token::Symbol') && $_->content eq '$VERSION' } @children;
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

sub _regex_sites ( $context, $token ) {
    my ( $start, $end ) = _span( $context, $token, $token ) or return;
    my $scope   = _scope( $context, $token ) or return;
    my $content = $token->content;
    my $regex   = PPIx::Regexp->new($content) or return;
    return if $regex->failures;
    my @parts = $regex->tokens;
    return if join( q{}, map { $_->content } @parts ) ne $content;

    my $offset = $start;
    for my $part (@parts) {
        my $text = $part->content;
        my $from = $offset;
        $offset += length $text;
        my $role = $REGEX_ROLE{ ref $part } or next;
        if ( $role eq 'flag' ) {
            my $index = index $text, 'i';
            next if $index < 0 || $text !~ /\A[[:alpha:]]+\z/;
            ( $from, $text ) = ( $from + $index, 'i' );
        }
        next if $role eq 'anchor' && !$ANCHOR{$text};
        _add( $context, kind => 'regex', start => $from, end => $from + length $text, role => $role, scope => $scope );
    }
    return;
}

sub _token_site ( $context, $token ) {
    return _regex_sites( $context, $token ) if grep { $token->isa($_) } @REGEX_TOKEN;
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
      : $kind eq 'word'     ? ( _word_role( $context, $token ), {} )
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

sub _word_role ( $context, $token ) {
    my $content  = $token->content;
    my $previous = $token->sprevious_sibling;
    my $next     = $token->snext_sibling;
    my $parent   = $token->parent;

    return q{} if _is_data_word( $previous, $next, $parent );

    my $segment = ref $parent eq 'PPI::Statement' ? $context->{segment_of}{ refaddr $token } : undef;
    my $heads   = $segment && refaddr( $segment->{children}[0] ) == refaddr $token;
    my $leads   = !$previous || $previous->isa('PPI::Token::Label') || $heads;
    if ( $CONDITIONAL{$content} ) {
        return 'compound' if $leads && ( $heads || $parent->isa('PPI::Statement::Compound') );
        return 'modifier' if !$leads;
        return q{};
    }
    return 'control' if $LOOP_CONTROL{$content} && $leads && ( $heads || $parent->isa('PPI::Statement::Break') );
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

sub _is_code_block ( $context, $block ) {
    my $parent = $block->parent;
    return 1
      if $parent->isa('PPI::Statement::Compound')
      || $parent->isa('PPI::Statement::Sub')
      || $parent->isa('PPI::Statement::Scheduled');
    return 1 if ref $parent eq 'PPI::Statement' && _segment_of( $context, $parent, $block )->{closes};
    my $previous = $block->sprevious_sibling;
    return 1 if !$previous;
    return 1 if $previous->isa('PPI::Structure::List') || $previous->isa('PPI::Structure::Signature');
    return 0 if !_is_name($previous);
    return 1 if $CODE_BLOCK_WORD{ $previous->content };
    my $before = $previous->sprevious_sibling;
    return $before && $before->isa('PPI::Token::Word') && $DECLARATOR{ $before->content } ? 1 : 0;
}

sub _running_statement ( $context, $element ) {
    my $statement = $element->isa('PPI::Statement') ? $element : $element->statement;
    while ($statement) {
        my $parent = $statement->parent or return $statement;
        return $statement if $parent->isa('PPI::Document');
        return $statement
          if ref $statement ne 'PPI::Statement::Expression'
          && $parent->isa('PPI::Structure::Block')
          && _is_code_block( $context, $parent );
        $statement = $parent->statement or return;
    }
    return;
}

sub _scope ( $context, $element ) {
    my $statement = _running_statement( $context, $element ) or return;
    my $segment   = ref $statement eq 'PPI::Statement' ? _segment_of( $context, $statement, $element ) : undef;
    return _segment_scope($segment) if $segment;
    my $key = refaddr $statement;
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
    if ( $node->isa('PPI::Statement::Sub') && !$node->isa('PPI::Statement::Scheduled') ) {
        my $block = $node->block;
        _add_body( $context, $block, $node->name // q{}, $node->first_token ) if $block;
    }
    _return_site( $context, scalar _scope( $context, $node ), $node->schildren ) if $node->isa('PPI::Statement::Break');
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

sub _body_site ( $context, $segment ) {
    my ( $head, $name ) = $segment->{children}->@*;
    my $block = $segment->{children}[-1];
    return if !$segment->{closes} || !_is_word( $head, \%BODY_HEAD ) || !$block->isa('PPI::Structure::Block');
    _add_body( $context, $block, $head->content eq 'ADJUST' ? 'ADJUST' : $name->content =~ s/\s*:\z//r, $head );
    return;
}

sub _add_body ( $context, $block, $name, $head ) {
    my ( $start, $end ) = _inner_span( $context, $block ) or return;
    my $first = $head->location          or return;
    my $last  = $block->finish->location or return;
    _add(
        $context,
        kind   => 'sub_body',
        start  => $start,
        end    => $end,
        scope  => [ $first->[0], $last->[0] ],
        detail => { name => $name },
    );
    return;
}

sub _return_site ( $context, $scope, $keyword, @rest ) {
    return if !$scope || !_is_word( $keyword, { return => 1 } );

    my @expression;
    for my $child (@rest) {
        last if _is_semicolon($child) || _is_word( $child, \%MODIFIER );
        push @expression, $child;
    }
    return if !@expression;

    my ( $start, $end ) = _span( $context, _edge_tokens( @expression[ 0, -1 ] ) ) or return;
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

sub _statement_site ( $context, $segment ) {
    my @children = $segment->{children}->@*;
    return if grep { $_->isa('PPI::Structure::Block') } @children;
    return if _is_word( $children[0], \%UNDELETABLE_FIRST_WORD );

    my @content = grep { !_is_semicolon($_) } @children;
    return if !@content;
    return if @content == 1 && ( $content[0]->isa('PPI::Token::Number') || $content[0]->isa('PPI::Token::Quote') );

    my ( $start, $end ) = _span( $context, _edge_tokens( @children[ 0, -1 ] ) ) or return;
    my $scope = _segment_scope($segment) or return;
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
