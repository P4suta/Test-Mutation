package Census;
use v5.36;
use PPI;
use PPI::Singletons ();
use PPIx::Regexp;
use Oracle;

# The census of the constructs of a corpus.
# PPI reads each file apart from the analysis of the tool, and every significant token gets the key of its construct.
# A key is claimed where a mutator of the catalog changes a token of that key.

# A sign after one of these words starts an operand.
my %BEFORE_AN_OPERAND = map { $_ => 1 } qw(
  return and or not xor if unless while until for foreach print say push unshift x eq ne lt gt le ge cmp
);

# A name after one of these words is the name of a declaration.
my %DECLARES = map { $_ => 1 } qw(sub package use no require method class);

# A mutator of these kinds of site changes one token, or a part of one.
my %TOKEN_SITE = map { $_ => 1 } qw(operator word number string regex);

# The tokens that hold a pattern, which the analysis reads with PPIx::Regexp.
my %PATTERN = map { ( "PPI::Token::$_" => 1 ) } qw(Regexp::Match Regexp::Substitute QuoteLike::Regexp);

# The constructs that no mutator changes, each with its reason.
# The table holds a construct that is syntax alone, and every other construct without a mutant is an open finding.
my %DECLINED = (
    'Structure'       => 'a brace, a bracket, a parenthesis, or a semicolon groups code and computes nothing',
    'operator ,'      => 'a comma separates the items of a list',
    'operator =>'     => 'a fat comma separates a key from its value',
    'operator ->'     => 'an arrow names the target of a dereference or of a call',
    'Symbol'          => 'the name of a variable has no counterpart that fits every place',
    'Magic'           => 'the name of a special variable has no counterpart that fits every place',
    'Cast'            => 'a sigil before a block or a reference names the type of the value',
    'Label'           => 'a label names a loop',
    'Prototype'       => 'a prototype belongs to the declaration of a subroutine',
    'Attribute'       => 'an attribute belongs to a declaration',
    'Separator'       => 'the end mark of the code holds no behavior',
    'Data'            => 'the text after the data mark is no code',
    'Number::Version' => 'a version number names a requirement',
);

sub declined () {
    return {%DECLINED};
}

sub _is ( $element, $class, @contents ) {
    return 0 if !$element || !$element->isa("PPI::Token::$class");
    return scalar grep { $element->content eq $_ } @contents;
}

sub _arity ($token) {
    my $content = $token->content;
    return q{} if $content ne q{+} && $content ne q{-};
    my $previous = $token->sprevious_sibling;
    my $starts =
         !$previous
      || ( $previous->isa('PPI::Token::Operator') && !_is( $previous, 'Operator', '++', '--' ) )
      || ( $previous->isa('PPI::Token::Word')     && $BEFORE_AN_OPERAND{ $previous->content } );
    return $starts ? ' (unary)' : ' (binary)';
}

# A keyword of perl in the place of a key, of a method, or of a declared name is a name like any other.
sub _is_keyword ($token) {
    return 0 if !$PPI::Singletons::KEYWORDS{ $token->content };    ## no critic (Variables::ProhibitPackageVars)
    my ( $previous, $next ) = ( $token->sprevious_sibling, $token->snext_sibling );
    return 0 if _is( $next, 'Operator', '=>' ) || _is( $previous, 'Operator', '->' );
    return 0 if $previous && $previous->isa('PPI::Token::Word') && $DECLARES{ $previous->content };
    my $alone = !$previous && !$next;
    return $alone && $token->parent->parent->isa('PPI::Structure::Subscript') ? 0 : 1;
}

sub key_of ($token) {
    my $class = ref($token) =~ s/\APPI::Token:://r;
    return 'operator ' . $token->content . _arity($token) if $class eq 'Operator';
    return $class                                         if $class ne 'Word';
    return _is_keyword($token) ? 'word ' . $token->content : 'Word';
}

# The spans of the changes that the given candidates propose, apart by what the generator made of each.
# A change that became a mutant claims its place, and a change that the generator refused with a rule declines it.
sub _changes (@candidates) {
    my ( @made, @refused );
    for my $candidate (@candidates) {
        my $span = [ $candidate->{site}->start, $candidate->{site}->end ];
        push @{ $candidate->{mutant} ? \@made : \@refused }, $span;
    }
    my @in_order = map {
        [ sort { $a->[0] <=> $b->[0] } $_->@* ]
    } \@made, \@refused;
    return @in_order;
}

# How many of the spans, each inside one of the ranges, each range holds.
# Both lists stand in the order of the file, and the ranges do not overlap.
sub _held ( $ranges, @spans ) {
    my @count = (0) x $ranges->@*;
    my $index = 0;
    for my $span ( sort { $a->[0] <=> $b->[0] } @spans ) {
        $index++ while $index != $ranges->@* && $span->[0] >= $ranges->[$index]{end};
        last if $index == $ranges->@*;
        my $range = $ranges->[$index];
        $count[$index]++ if $span->[0] >= $range->{start} && $range->{end} >= $span->[1];
    }
    return @count;
}

sub _key_records ( $tokens, $made, $refused ) {
    my @claimed  = _held( $tokens, $made->@* );
    my @declined = _held( $tokens, $refused->@* );
    my ( %observed, %claimed, %refused );
    for my $index ( 0 .. $#claimed ) {
        my $key = key_of( $tokens->[$index]{token} );
        $observed{$key}++;
        $claimed{$key}++ if $claimed[$index];
        $refused{$key}++ if !$claimed[$index] && $declined[$index];
    }
    return map { [ 'key', $_, $observed{$_}, $claimed{$_} || 0, $refused{$_} || 0 ] } sort keys %observed;
}

# The patterns of a source that PPIx::Regexp reads with a failure or reads as another text.
sub _unparsed ($tokens) {
    my $count = 0;
    for my $token ( grep { $PATTERN{ $_->{class} } } $tokens->@* ) {
        my $pattern = PPIx::Regexp->new( $token->{content} );
        my $sound =
          $pattern && !$pattern->failures && join( q{}, map { $_->content } $pattern->tokens ) eq $token->{content};
        $count++ if !$sound;
    }
    return $count;
}

# A statement that runs: a declaration of a package or of a subroutine and an empty statement hold no code of their own.
my %NO_CODE = map { $_ => 1 } qw(
  PPI::Statement::Package PPI::Statement::Sub PPI::Statement::Scheduled PPI::Statement::Null PPI::Statement::End
  PPI::Statement::Data PPI::Statement::UnmatchedBrace PPI::Statement::Unknown
);

# Whether one of the spans lies inside the range.
# The spans stand in the order of their starts, so the search begins at the first span that starts in the range.
# A span around the range, such as the body of the subroutine that holds a statement, belongs to no statement.
sub _holds ( $from, $to, $spans ) {
    my ( $low, $high ) = ( 0, scalar $spans->@* );
    while ( $low != $high ) {
        my $sum    = $low + $high;
        my $middle = int( $sum / 2 );
        if ( $spans->[$middle][0] >= $from ) {
            $high = $middle;
        }
        else {
            $low = $middle + 1;
        }
    }
    while ( $low != $spans->@* && $to >= $spans->[$low][0] ) {
        return 1 if $to >= $spans->[$low][1];
        $low++;
    }
    return 0;
}

sub _statement_records ( $document, $offset_of, $made, $refused ) {
    my ( %all, %bare, %refused );
    for my $statement ( grep { !$NO_CODE{ ref $_ } } @{ $document->find('PPI::Statement') || [] } ) {
        my ( $first, $last ) = ( $statement->first_token, $statement->last_token );
        my $from = $offset_of->{ $first->location->[0] }{ $first->location->[1] };
        my $to   = $offset_of->{ $last->location->[0] }{ $last->location->[1] };
        next if !defined $from || !defined $to;
        my $class = ref($statement) =~ s/\APPI:://r;
        $all{$class}++;
        my $end = $to + length $last->content;
        next if _holds( $from, $end, $made );
        my $declined = _holds( $from, $end, $refused );
        $refused{$class}++ if $declined;
        $bare{$class}++    if !$declined;
    }
    return map { [ 'statement', $_, $all{$_}, $bare{$_} || 0, $refused{$_} || 0 ] } sort keys %all;
}

# The census of one source as records: the keys with their counts, the statements by class, and the tokens without a place.
sub records ($source) {
    my $read   = Oracle::tokens($source);
    my $made   = Oracle::generated($source);
    my $tokens = $read->{tokens};
    my %offset_of;
    $offset_of{ $_->{token}->location->[0] }{ $_->{token}->location->[1] } = $_->{start} for $tokens->@*;
    my @candidates = defined $made->{problem} ? () : Oracle::candidates( $source, $made )->@*;
    my ( $made_of_token, $refused_of_token ) = _changes( grep { $TOKEN_SITE{ $_->{site}->kind } } @candidates );
    my ( $made_at_all, $refused_at_all )     = _changes(@candidates);
    my @dropped = grep { $_->{kind} eq 'regex' } ( $made->{dropped} || [] )->@*;
    return (
        [ 'unplaced', $read->{unplaced} ],
        [ 'dropped',  scalar @dropped, _unparsed($tokens) ],
        _key_records( $tokens, $made_of_token, $refused_of_token ),
        $read->{document}
        ? _statement_records( $read->{document}, \%offset_of, $made_at_all, $refused_at_all )
        : (),
    );
}

# The records of a walk as the counts of each key, the statements of each class, and the statements of each file.
# `refused` holds the places where the generator refused every change with a rule, which declines them with a reason.
# `dropped` holds the patterns that the analysis counts as left out, and `unparsed` the ones that PPIx::Regexp fails on.
sub summary ($records) {
    my %census = (
        observed   => {},
        claimed    => {},
        refused    => {},
        statements => {},
        files      => {},
        unplaced   => 0,
        dropped    => 0,
        unparsed   => 0,
    );
    for my $record ( $records->@* ) {
        my ( $path, $kind, @fields ) = $record->@*;
        if ( $kind eq 'unplaced' ) {
            $census{unplaced} += $fields[0];
        }
        elsif ( $kind eq 'dropped' ) {
            $census{dropped}  += $fields[0];
            $census{unparsed} += $fields[1];
        }
        else {
            _add_record( \%census, $path, $kind, @fields );
        }
    }
    return \%census;
}

sub _add_record ( $census, $path, $kind, @fields ) {
    if ( $kind eq 'key' ) {
        my ( $key, $observed, $claimed, $refused ) = @fields;
        $census->{observed}{$key} += $observed;
        $census->{claimed}{$key}  += $claimed if $claimed;
        $census->{refused}{$key}  += $refused if $refused;
        return;
    }
    my ( $class, $all, $bare, $refused ) = @fields;
    $census->{statements}{$class}{$_}      += 0 for qw(all bare refused);
    $census->{statements}{$class}{all}     += $all;
    $census->{statements}{$class}{bare}    += $bare;
    $census->{statements}{$class}{refused} += $refused || 0;
    $census->{files}{$path}{all}           += $all;
    $census->{files}{$path}{bare}          += $bare;
    return;
}

# The gaps of a census: a key without a mutant and without a reason, and a reason that stands beside a mutant or beside nothing.
# A key whose changes the generator refuses with a rule has its reason in that rule.
sub undecided ( $census, $declined ) {
    my ( $observed, $claimed ) = $census->@{qw(observed claimed)};
    my $refused = $census->{refused} || {};
    my @open    = grep { !$claimed->{$_} && !$refused->{$_} && !exists $declined->{$_} } keys $observed->%*;
    my @both    = grep { $claimed->{$_} } keys $declined->%*;
    my @never   = grep { !$observed->{$_} } keys $declined->%*;
    my @gaps    = (
        ( map { "no mutant covers $_, and no reason declines it" } @open ),
        ( map { "a mutant covers $_, and a reason declines it" } @both ),
        ( map { "a reason declines $_, and the corpus never shows it" } @never ),
    );
    return [ sort @gaps ];
}

# The analysis reads a pattern with PPIx::Regexp and counts the ones that it leaves out.
# The census reads the same patterns on its own, in the code of a use statement too, which the analysis never reads.
# A count of the analysis below the count of the census outside those statements is a pattern left out in silence.
sub uncounted ($census) {
    return [
        $census->{dropped} >= $census->{unparsed}
        ? ()
        : 'the analysis leaves out a pattern that PPIx::Regexp cannot read, without a count'
    ];
}

# The keys of a census that another census never shows, as a census of its own.
sub beyond ( $far, $near ) {
    my @keys = grep { !$near->{observed}{$_} } keys $far->{observed}->%*;
    return {
        observed   => { map { $_ => $far->{observed}{$_} } @keys },
        claimed    => { map { $_ => $far->{claimed}{$_} } grep { $far->{claimed}{$_} } @keys },
        refused    => { map { $_ => $far->{refused}{$_} } grep { $far->{refused}{$_} } @keys },
        statements => {},
        files      => {},
        unplaced   => 0,
    };
}

# The classes of statement that the tool leaves without a mutant in every place.
sub bare_classes ($census) {
    my $statements = $census->{statements};
    return [ grep { $statements->{$_}{bare} == $statements->{$_}{all} } sort keys $statements->%* ];
}

# The files with the largest share of statements without a mutant, each with both counts.
sub barest_files ( $census, $limit ) {
    my $files = $census->{files};
    my %share;
    for my $path ( keys $files->%* ) {
        my ( $bare, $all ) = $files->{$path}->@{qw(bare all)};
        $share{$path} = $bare / $all;
    }
    my @sorted = sort { $share{$b} <=> $share{$a} || $a cmp $b } keys %share;
    return map { [ $_, $files->{$_}->@{qw(bare all)} ] } grep { defined } @sorted[ 0 .. $limit - 1 ];
}

1;
