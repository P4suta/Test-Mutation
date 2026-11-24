package Test::Mutation::Syntax::PPI;
use v5.36;
use PPI;
use PPIx::Regexp;
use Scalar::Util    qw(refaddr);
use Types::Standard qw(InstanceOf);
use Type::Params    qw(signature_for);
use Test::Mutation::Site;
use Test::Mutation::Types qw(Analysis);

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
my %BOUNDED_COMPARISON = map { $_ => 1 } qw(< <= > >=);
my %LIST_BLOCK_WORD    = map { $_ => 1 } qw(map grep);
my %DECLARATION        = map { $_ => 1 } qw(my our state);
my %OPEN_BLOCK_HEAD    = map { $_ => 1 } qw(ADJUST if unless while until for foreach);
my %BLOCK_FIRST_HEAD   = map { $_ => 1 } qw(finally defer try);
my %NAMED_BLOCK_HEAD   = map { $_ => 1 } qw(class role method sub);
my %CONTINUATION       = map { $_ => 1 } qw(elsif else continue catch finally);
my %BODY_HEAD          = map { $_ => 1 } qw(method sub ADJUST);
my %EXCLUDED_HEAD      = map { $_ => 1 } qw(use no package);
my %HIDDEN_HEAD        = map { $_ => 1 } qw(field ADJUST);
my %NEVER_A_CALL =
  map { $_ => 1 }
  qw(my our local state sub package class role field method use no return do eval else elsif for foreach
  continue given when default try catch finally defer BEGIN END INIT CHECK UNITCHECK ADJUST
  __PACKAGE__ __FILE__ __LINE__ __SUB__ __CLASS__);

my %TIGHTER_THAN_PRODUCT = map { $_ => 1 } qw(** =~ !~ ++ -- ->);
my %TIGHTER_THAN_SUM     = ( %TIGHTER_THAN_PRODUCT, map { $_ => 1 } qw(* / % x) );
my %BINDS_TIGHTER_THAN =
  ( ( map { $_ => \%TIGHTER_THAN_SUM } qw(+ -) ), ( map { $_ => \%TIGHTER_THAN_PRODUCT } qw(* / % **) ), );

my @BEFORE_A_SUB_BODY = qw(PPI::Structure::List PPI::Structure::Signature PPI::Token::Prototype PPI::Token::Attribute);
my @REGEX_TOKEN       = qw(PPI::Token::Regexp::Match PPI::Token::Regexp::Substitute PPI::Token::QuoteLike::Regexp);
my %REGEX_ROLE        = (
    'PPIx::Regexp::Token::Assertion'  => 'anchor',
    'PPIx::Regexp::Token::Quantifier' => 'quantifier',
    'PPIx::Regexp::Token::Modifier'   => 'flag',
);
my %ANCHOR = map { $_ => 1 } ( q{^}, q{$}, '\\A', '\\z', '\\Z' );

signature_for analyze => ( positional => [ InstanceOf ['Test::Mutation::Source'] ], returns => Analysis );

sub analyze ($source) {
    my $text = $source->text;

    # Perl skips a byte order mark and PPI rejects it, so the parser reads the text after the mark.
    my $mark = $text =~ /\A\x{feff}/ ? 1 : 0;

    # PPI ends a line at its line feed, and a line keeps its columns without the carriage return before the feed.
    my $copy = substr( $text, $mark ) =~ s/\r\n/\n/gr;
    return _problem('the file has a carriage return without a line feed') if $copy =~ /\r/;
    my $document = _document($copy);
    if ( !$document ) {
        my $reason = PPI::Document->errstr;
        return _problem( 'PPI cannot parse the file: ' . ( defined $reason ? $reason : 'unknown error' ) );
    }
    return _problem('PPI does not reproduce the file') if $document->serialize ne $copy;

    my $context = { source => $source, text => $text, mark => $mark, scopes => {}, sites => [], dropped => [] };
    _visit( $context, $document, 0 );
    my @sites = sort { $a->start <=> $b->start || $a->end <=> $b->end } $context->{sites}->@*;
    return {
        sites        => \@sites,
        suppressions => _suppressions($document),
        dropped      => $context->{dropped},
        problem      => undef
    };
}

sub _problem ($message) {
    return { sites => [], suppressions => [], dropped => [], problem => $message };
}

# PPI learns from a few pragmas that a file uses signatures, and it reads the signature of another file as a prototype.
# A prototype holds no letter, so a letter there means a signature, and PPI reads the file again with signatures on.
sub _document ($copy) {
    my $document = PPI::Document->new( \$copy ) or return;
    my $letters  = grep { $_->content =~ /[[:alpha:]]/ } @{ $document->find('PPI::Token::Prototype') || [] };
    return $letters ? PPI::Document->new( \$copy, feature_mods => { signatures => 1 } ) : $document;
}

# A place that yields no site is a place without mutants, so each one is kept for the report of the run.
# The analysis may ask for the place of one token more than once, and the token counts once, where it first came up.
sub _drop ( $context, $token, $kind, $reason ) {
    return if $context->{is_dropped}{ refaddr $token };
    $context->{is_dropped}{ refaddr $token } = 1;
    my $location = $token->location;
    push $context->{dropped}->@*, { line => $location ? $location->[0] : 0, kind => $kind, reason => $reason };
    return;
}

sub _visit ( $context, $element, $excluded ) {
    if ( $element->isa('PPI::Token') ) {
        _token_site( $context, $element ) if !$excluded && $element->significant;
        return;
    }
    return _visit_segments( $context, $element, $excluded ) if ref $element eq 'PPI::Statement';
    my $skip = $excluded || _excluded($element);
    _structure_sites( $context, $element ) if !$skip;

    # The name and the version of a package hold no behavior, and its block holds ordinary code.
    # The body of an anonymous subroutine runs later, whatever statement holds it, such as a use of overload.
    my $package = $element->isa('PPI::Statement::Package');
    for my $child ( $element->children ) {
        my $apart = $skip || ( $package && !$child->isa('PPI::Structure::Block') );
        _visit( $context, $child, _is_anonymous_body($child) ? 0 : $apart );
    }
    return;
}

sub _is_anonymous_body ($element) {
    return 0 if !$element->isa('PPI::Structure::Block');
    my $before = $element->sprevious_sibling;
    $before = $before->sprevious_sibling while $before && grep { $before->isa($_) } @BEFORE_A_SUB_BODY;
    return 0 if !_is_word( $before, { sub => 1 } );

    # A named subroutine is a statement of its own, and its name stands between the word and the block.
    return $element->parent->isa('PPI::Statement::Sub') ? 0 : 1;
}

sub _visit_segments ( $context, $statement, $excluded ) {
    my $parent = $statement->parent;
    my $runs =
      $parent->isa('PPI::Document') || ( $parent->isa('PPI::Structure::Block') && _is_code_block( $context, $parent ) );
    for my $segment ( _segments( $context, $statement )->@* ) {
        my @children = $segment->{children}->@*;
        my $skip     = $excluded || _is_word( $children[0], \%EXCLUDED_HEAD ) || _holds_version(@children);

        # B::Deparse prints neither a field nor an ADJUST block.
        local $context->{hidden} = 1 if _is_word( $children[0], \%HIDDEN_HEAD );
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
        my $kept = _is_word( $head, { class => 1, role => 1 } ) ? 'PPI::Structure::Block' : 'PPI::Structure';
        return grep { !$_->isa($kept) } @rest;
    }
    return if !_is_word( $head, { field => 1 } );
    my ($stop) = grep { _is_semicolon( $rest[$_] ) || _is_operator( $rest[$_], q{=}, '//=', '||=' ) } 1 .. $#rest;
    return @rest[ 1 .. ( defined $stop ? $stop : scalar @rest ) - 1 ];
}

sub _is_word ( $element, $words ) {
    return $element && $element->isa('PPI::Token::Word') && $words->{ $element->content } ? 1 : 0;
}

sub _is_semicolon ($element) {
    return $element->isa('PPI::Token::Structure') ? 1 : 0;
}

sub _ends_at_block ( $head, $next, $after ) {
    return 1                                                    if _is_word( $head,  \%OPEN_BLOCK_HEAD );
    return $next && $next->isa('PPI::Structure::Block') ? 1 : 0 if _is_word( $head,  \%BLOCK_FIRST_HEAD );
    return 0                                                    if !_is_word( $head, \%NAMED_BLOCK_HEAD );

    # PPI reads a name before an attribute, as in "method name :lvalue", as a label.
    return 1 if $next && $next->isa('PPI::Token::Label');
    return _is_name($next) && !_is_operator( $after, '=>', q{,} ) ? 1 : 0;
}

# PPI ends a statement it does not know, such as a method or a defer block, at the next semicolon.
sub _segments ( $context, $statement ) {
    my @children = $statement->schildren;
    my @segments;
    while (@children) {
        my @part = shift @children;
        my ( $next, $after ) = @children;
        my $closes = _ends_at_block( $part[0], $next, $after );
        while (@children) {
            push @part, shift @children;
            last if $closes && $part[-1]->isa('PPI::Structure::Block') && !_is_word( $children[0], \%CONTINUATION );
        }
        my $segment = { children => \@part, closes => $closes };
        $context->{segment_of}{ refaddr $_ } = $segment for @part;
        push @segments, $segment;
    }
    return \@segments;
}

sub _segment_of ( $context, $statement, $element ) {
    my $child = $element;
    while ( my $parent = $child->parent ) {
        return $context->{segment_of}{ refaddr $child } if refaddr($parent) == refaddr $statement;
        $child = $parent;
    }
    return;
}

sub _segment_scope ($segment) {
    $segment->{scope} ||= [ map { $_->location->[0] } _edge_tokens( $segment->{children}->@[ 0, -1 ] ) ];
    return $segment->{scope};
}

sub _edge_tokens ( $first, $last ) {
    return (
        $first->isa('PPI::Token') ? $first : $first->first_token,
        $last->isa('PPI::Token')  ? $last  : $last->last_token
    );
}

sub _excluded ($node) {
    return 1 if $node->isa('PPI::Statement::Include');
    return 0 if !$node->isa('PPI::Statement');
    return _holds_version( $node->schildren );
}

sub _holds_version (@children) {
    return scalar grep { $_->isa('PPI::Token::Symbol') && $_->content eq '$VERSION' } @children;
}

sub _offset ( $context, $token ) {
    my $location = $token->location or return;
    my $offset   = $context->{source}->offset_of( $location->[0], $location->[1] );
    $offset += $context->{mark} if $location->[0] == 1;
    my $content = $token->content;
    return $offset if substr( $context->{text}, $offset, length $content ) eq $content;
    _drop( $context, $token, 'span', 'the text at the place differs from the token' );
    return;
}

sub _span ( $context, $first, $last ) {
    my $start = _offset( $context, $first );
    my $end   = _offset( $context, $last );
    return if !defined $start || !defined $end;
    return ( $start, $end + length $last->content );
}

sub _add ( $context, %site ) {
    $site{text}       = substr $context->{text}, $site{start}, $site{end} - $site{start};
    $site{comparable} = $context->{hidden} ? 0 : 1;
    push $context->{sites}->@*, Test::Mutation::Site->new(%site);
    return;
}

sub _regex_sites ( $context, $token ) {
    my ( $start, $end ) = _span( $context, $token, $token ) or return;
    my $scope   = _scope( $context, $token ) or return;
    my $content = $token->content;
    my $regex   = PPIx::Regexp->new($content);
    my @parts   = $regex && !$regex->failures ? $regex->tokens : ();
    return _drop( $context, $token, 'regex', 'the pattern does not parse' )
      if join( q{}, map { $_->content } @parts ) ne $content;

    my $offset = $start;
    for my $part (@parts) {
        my $text = $part->content;
        my $from = $offset;
        $offset += length $text;
        my $role = $REGEX_ROLE{ ref $part } or next;
        if ( $role eq 'flag' ) {
            my ($before) = $text =~ /\A([[:alpha:]]*?)i[[:alpha:]]*\z/ or next;
            ( $from, $text ) = ( $from + length $before, 'i' );
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
      : $token->isa('PPI::Token::Prototype')       ? undef
      : $token->isa('PPI::Token::Number')          ? 'number'
      : $token->isa('PPI::Token::Quote')           ? 'string'
      :                                              undef;
    return if !defined $kind;

    my ( $start, $end ) = _span( $context, $token, $token ) or return;
    my $scope = _scope( $context, $token ) or return;
    my ( $role, $facts ) =
        $kind eq 'operator' ? _operator_role($token)
      : $kind eq 'word'     ? ( _word_role( $context, $token ), {} )
      :                       ( q{}, {} );
    return if $kind eq 'word' && $role eq q{};
    _add(
        $context,
        kind  => $kind,
        start => $start,
        end   => $end,
        role  => $role,
        scope => $scope,
        facts => $facts,
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
    return ( 'unary',  {} ) if $content eq '!' || $content eq '~' || $content eq 'not';
    return ( 'binary', { _right_number($token)->%*, _version_literal($token) } );
}

# A comparison of the version of Perl with a literal has one result on each interpreter.
sub _version_literal ($token) {
    return if !$BOUNDED_COMPARISON{ $token->content };
    my @sides    = grep { ref } $token->sprevious_sibling, $token->snext_sibling;
    my ($number) = grep { $_->isa('PPI::Token::Number') && !$_->isa('PPI::Token::Number::Version') } @sides;
    my ($perl)   = grep { $_->content eq '$]' || $_->content eq '"$]"' } @sides;
    my $value    = $number && $perl ? $number->literal : undef;
    return defined $value ? ( version => 0 + $value ) : ();
}

# A number is the whole right operand unless the operator after it binds tighter.
sub _right_number ($token) {
    my $tighter = $BINDS_TIGHTER_THAN{ $token->content } or return {};
    my $number  = $token->snext_sibling;
    return {} if !$number || !$number->isa('PPI::Token::Number') || $number->isa('PPI::Token::Number::Version');
    my $after = $number->snext_sibling;
    return {} if $after && $after->isa('PPI::Token::Operator') && $tighter->{ $after->content };
    my $value = $number->literal;
    return defined $value ? { right => 0 + $value } : {};
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
        return $leads ? 'compound' : 'modifier';
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
    return $element && ( $element->isa('PPI::Token::Word') || $element->content eq 'x' ) ? 1 : 0;
}

sub _is_code_block ( $context, $block ) {
    my $parent = $block->parent;

    # PPI reads the braces of a file handle inside the parentheses of print as a bare block.
    return 0 if $parent->isa('PPI::Statement::Compound') && $parent->parent->isa('PPI::Structure::List');
    return 1 if $parent->isa('PPI::Statement::Compound') || $parent->isa('PPI::Statement::Package');
    return 1 if ref $parent eq 'PPI::Statement' && _segment_of( $context, $parent, $block )->{closes};
    my $previous = $block->sprevious_sibling;
    return 1 if $previous && grep { $previous->isa($_) } @BEFORE_A_SUB_BODY;
    return 0 if !_is_name($previous);
    return 1 if $CODE_BLOCK_WORD{ $previous->content };
    return _is_word( scalar $previous->sprevious_sibling, \%DECLARATOR );
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
    $context->{scopes}{$key} ||= [ map { $_->location->[0] } $statement->first_token, $statement->last_token ];
    return $context->{scopes}{$key};
}

sub _structure_sites ( $context, $node ) {
    _condition_site( $context, $node ) if $node->isa('PPI::Structure::Condition');
    return                             if !$node->isa('PPI::Statement');
    if ( $node->isa('PPI::Statement::Sub') && !$node->isa('PPI::Statement::Scheduled') ) {
        my $block = $node->block;
        my $name  = $node->name;
        _add_body( $context, $block, defined $name ? $name : q{}, $node->first_token ) if $block;
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
        kind  => 'condition',
        start => $start,
        end   => $end,
        scope => $scope,
        facts => { keyword => $keyword ? $keyword->content : q{} },
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
        kind  => 'sub_body',
        start => $start,
        end   => $end,
        scope => [ $first->[0], $last->[0] ],
        facts => { name => $name },
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
        kind  => 'return',
        start => $start,
        end   => $end,
        scope => $scope,
        facts => { defined $literal ? ( literal => $literal ) : () },
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

    # The text of a here-document follows its line, so the removal of the statement leaves that text as code.
    my @tokens = map { $_->isa('PPI::Token') ? $_ : $_->tokens } @children;
    return if grep { $_->isa('PPI::Token::HereDoc') } @tokens;
    return if _is_whole_list_block( $children[0]->parent );

    my ( $start, $end ) = _span( $context, _edge_tokens( @children[ 0, -1 ] ) ) or return;
    return if _declares_for_later( $context, $children[0]->parent, \@tokens, $end );
    my $scope = _segment_scope($segment) or return;
    _add(
        $context,
        kind  => 'statement',
        start => $start,
        end   => $end,
        scope => $scope,
        facts => { head => $children[0]->isa('PPI::Token::Word') ? $children[0]->content : q{} },
    );
    return;
}

# Perl reads the empty braces after map or grep as a hash, so the one statement of such a block must stay.
sub _is_whole_list_block ($statement) {
    my $block = $statement->parent;
    return 0 if !$block->isa('PPI::Structure::Block') || $block->schildren != 1;
    return _is_word( scalar $block->sprevious_sibling, \%LIST_BLOCK_WORD );
}

# A variable that the statement declares and later code of the block names needs its declaration under strict.
sub _declares_for_later ( $context, $statement, $tokens, $end ) {
    my @names = map { $_->content =~ /\A[\$\@%](\w+)\z/ } grep {
        my $list = $_->parent->parent;
        $_->isa('PPI::Token::Symbol')
          && ( _is_word( scalar $_->sprevious_sibling, \%DECLARATION )
            || ( $list->isa('PPI::Structure::List') && _is_word( scalar $list->sprevious_sibling, \%DECLARATION ) ) )
    } $tokens->@*;

    # The block of the statement bounds the variable, and a file has no closing brace.
    my $block  = $statement->parent;
    my $finish = $block->isa('PPI::Structure::Block') ? $block->finish               : undef;
    my $limit  = $finish                              ? _offset( $context, $finish ) : undef;
    my $later  = substr $context->{text}, $end, ( defined $limit ? $limit : length $context->{text} ) - $end;
    return scalar grep { $later =~ /[\$\@%]\#?\{?\Q$_\E\b/ } @names;
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

Test::Mutation::Syntax::PPI - find mutation sites with PPI

=head1 SYNOPSIS

    my $analysis = Test::Mutation::Syntax::PPI::analyze($source);
    die $analysis->{problem} if defined $analysis->{problem};
    my @sites = $analysis->{sites}->@*;

=head1 DESCRIPTION

The module parses a source with PPI and reports the places a mutator can change.
It verifies that every reported span holds the text PPI attributes to it.
A span that fails the check and a pattern that L<PPIx::Regexp> fails to parse yield no site, and the result lists each of them.
C<use> and C<no> statements, the name and the version of a C<package>, C<$VERSION> assignments, and text after C<__END__> produce no sites.
The block of a C<package> holds sites like any other code, and so does the body of an anonymous subroutine inside a C<use> statement.

PPI learns from C<use v5.36> and a few other pragmas that a file uses signatures.
In another file it reads a signature as a prototype, and the module then reads the file again with signatures on.
A file with a carriage return before each line feed is analyzed, and its sites address the text with the carriage returns.
There a token that spans two lines has another text than the file, so it is among the places left out.

PPI joins the code after a method, a C<defer> block, or a C<finally> block to the block.
The module splits such a statement at the closing brace, so each part has its own scope and its own sites.
The name, the version, and the attributes of a class, a field, or a method produce no sites.
A site in a field or in an C<ADJUST> block is marked as not comparable.

A statement is no statement site when the file does not compile without it.
That holds for the one statement of a C<map> or C<grep> block, for a statement with a here-document, and for a statement that declares a variable which later code of the block names.
The braces around a file handle hold no statement.

=head1 FUNCTIONS

=head2 analyze

Returns a hash reference in the shape of L<Test::Mutation::Types/Analysis>.
C<sites> holds L<Test::Mutation::Site> objects in source order.
C<suppressions> holds the line ranges that C<## no mutate> comments cover.
C<dropped> holds the places that yield no site, each with its line, its kind, and the reason.
C<problem> names the reason when the file cannot be analyzed.

=cut
