package Snippets;
use v5.36;
use PPI::Singletons ();
use Judge;
use Oracle;

# The generator of snippets: an operator of PPI between two operands, in a context that runs the expression.
# The list holds no random part, so two runs make the same snippets in the same order.

# The entries of the table of PPI that stand in no place between two operands.
my %NOT_BETWEEN = map { $_ => 1 } qw(-> ++ -- ! ~ ~. ? : => <> <<>> not), q{,};

# Perl 5.42 removed the smartmatch operator, so a snippet with it is code on one interpreter and none on the next.
my %NOT_IN_EVERY_PERL = ( q{~~} => 1 );

sub operators () {
    my @all = sort keys %PPI::Singletons::OPERATOR;    ## no critic (Variables::ProhibitPackageVars)
    return grep { !$NOT_BETWEEN{$_} && !$NOT_IN_EVERY_PERL{$_} } @all;
}

# The shapes of an operand, each as the text on the left and on the right of an operator.
my @OPERANDS = (
    { name => 'variable',            left => '$x',              right => '$y' },
    { name => 'literal',             left => '7',               right => '2' },
    { name => 'call',                left => 'f($x)',           right => 'f($y)' },
    { name => 'dereference',         left => '$r->{k}',         right => '$r->{list}[1]' },
    { name => 'postfix dereference', left => '$r->{list}->$#*', right => '$r->{list}->$#*' },
    { name => 'parenthesised',       left => '( $x )',          right => '( $y )' },
    { name => 'here-document',       left => q{<<'EOT'},        right => q{<<'EOT'}, body => "7\nEOT\n" },
);

sub operands () {
    return @OPERANDS;
}

sub expression ( $operator, $before, $after ) {
    my $body = join q{}, grep { defined } $before->{body}, $after->{body};
    return { text => "$before->{left} $operator $after->{right}", body => $body, operator => $operator };
}

# PPI knows the signatures of a file from its `use v5.36`.
# The other header turns the feature on in a block, as a pragma of a project does, and PPI reads the signature as a prototype.
my $KNOWN   = "use v5.36;\nno warnings;\n";
my $UNKNOWN = "use v5.20;\nBEGIN { require feature; feature->import(qw(signatures bitwise)) }\nno warnings;\n";

# The contexts that run an expression, each as the code of one package with EXPR in the place of the expression.
# `last` marks the context whose expression ends the file in the place of the true value.
# `loads` marks a context that runs its expression when the file loads, so perl loads each mutant there too.
my @CONTEXTS = (
    { name => 'assignment',                        code => 'sub c { my $v = EXPR; return $v }' },
    { name => 'statement',                         code => 'EXPR;', loads => 1 },
    { name => 'return',                            code => 'sub c { return EXPR }' },
    { name => 'argument',                          code => 'sub c { return f(EXPR) }' },
    { name => 'compound condition',                code => 'sub c { if (EXPR) { return 1 } return 0 }' },
    { name => 'modifier',                          code => 'sub c { return 1 if EXPR; return 0 }' },
    { name => 'ternary condition',                 code => 'sub c { return EXPR ? 1 : 0 }' },
    { name => 'ternary first branch',              code => 'sub c { return $x ? EXPR : 0 }' },
    { name => 'ternary second branch',             code => 'sub c { return $x ? 0 : EXPR }' },
    { name => 'signature default',                 code => 'sub c ( $v = EXPR ) { return $v }' },
    { name => 'signature default, unknown to PPI', code => 'sub c ( $v = EXPR ) { return $v }', header => $UNKNOWN },
    { name => 'map block',               code => 'sub c { return map { EXPR } 1 .. 3 }' },
    { name => 'grep block',              code => 'sub c { return grep { EXPR } 1 .. 3 }' },
    { name => 'sort block',              code => 'sub c { return sort { EXPR } 1 .. 3 }' },
    { name => 'here-document statement', code => "sub c { my \@v = ( EXPR, <<'TEXT' ); return \@v }\ntext\nTEXT" },
    { name => 'or die',                  code => q{sub c { EXPR or die 'no value'; return 1 }} },
    { name => 'final statement',         code => 'EXPR;', last => 1, loads => 1 },
    { name => 'BEGIN block',             code => 'BEGIN { my $v = EXPR; }' },
    { name => 'use statement',           code => 'use constant LIMIT => EXPR;' },
);

sub contexts () {
    return map { { header => $KNOWN, $_->%* } } @CONTEXTS;
}

# The sizes of the four axes of a snippet: the operator, the operand on each side, and the context.
sub sizes () {
    return ( scalar( () = operators() ), scalar @OPERANDS, scalar @OPERANDS, scalar @CONTEXTS );
}

# Every tuple of one value from each axis.
sub product (@sizes) {
    my @tuples = ( [] );
    for my $size (@sizes) {
        my @longer;
        for my $head (@tuples) {
            push @longer, map { [ $head->@*, $_ ] } 0 .. $size - 1;
        }
        @tuples = @longer;
    }
    return @tuples;
}

sub _best_value ( $row, $size, $uncovered ) {
    my ( $best, $gain ) = ( 0, -1 );
    for my $value ( 0 .. $size - 1 ) {
        my $covers = grep { $uncovered->{"$_ $row->[$_] $value"} } 0 .. $row->$#*;
        ( $best, $gain ) = ( $value, $covers ) if $covers > $gain;
    }
    return $best;
}

# A row for each pair that no row holds yet, filled with other pairs that still wait.
sub _rows_for ( $uncovered, $width ) {
    my @rows;
    for my $pair (
        sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] }
        map  { [ split / / ] } keys $uncovered->%*
      )
    {
        my ( $column, $value, $new ) = $pair->@*;
        next if !delete $uncovered->{"$column $value $new"};
        my @row = (0) x $width;
        $row[$column] = $value;
        for my $other ( grep { $_ != $column } 0 .. $width - 1 ) {
            my ($waiting) =
              sort { $a <=> $b } map { ( split / / )[1] } grep { /\A$other \d+ $new\z/ } keys $uncovered->%*;
            next if !defined $waiting;
            $row[$other] = $waiting;
            delete $uncovered->{"$other $waiting $new"};
        }
        push @rows, [ @row, $new ];
    }
    return @rows;
}

# Tuples in which every value of an axis meets every value of every other axis, built one axis after the other.
# The two largest axes start with their product, and each further axis takes the value that covers the most new pairs.
sub pairwise (@sizes) {
    my @order = sort { $sizes[$b] <=> $sizes[$a] || $a <=> $b } 0 .. $#sizes;
    my @rows  = product( @sizes[ @order[ 0, 1 ] ] );
    for my $position ( 2 .. $#order ) {
        my $size = $sizes[ $order[$position] ];
        my %uncovered;
        for my $column ( 0 .. $position - 1 ) {
            for my $value ( 0 .. $sizes[ $order[$column] ] - 1 ) {
                $uncovered{"$column $value $_"} = 1 for 0 .. $size - 1;
            }
        }
        for my $row (@rows) {
            my $value = _best_value( $row, $size, \%uncovered );
            delete $uncovered{"$_ $row->[$_] $value"} for 0 .. $row->$#*;
            push $row->@*, $value;
        }
        push @rows, _rows_for( \%uncovered, $position );
    }
    my @tuples;
    for my $row (@rows) {
        my @tuple;
        @tuple[@order] = $row->@*;
        push @tuples, \@tuple;
    }
    return @tuples;
}

sub _package ( $index, $context, $expression ) {
    my $head = join q{}, "package Snippet::N$index;\n", "our ( \$x, \$y, \$r );\n",
      "BEGIN { ( \$x, \$y, \$r ) = ( 3, 4, { k => 5, list => [ 1, 2 ] } ) }\n", "sub f { return \$_[0] }\n";
    my ( $before, $after ) = split /EXPR/, $context->{code}, 2;
    my ( $line, $rest ) = $after =~ /\A([^\n]*)(.*)\z/s;

    # The text of a here-document starts on the line after its introducer.
    my $tail = $line . "\n" . $expression->{body} . ( length $rest ? substr( $rest, 1 ) . "\n" : q{} );
    return ( $head, $before, $expression->{text}, $tail );
}

# One file with a package for each expression in the context.
# `spans` holds the span of each expression, and `codes` holds the place where the code of each context starts.
sub file ( $context, @expressions ) {
    my $text = $context->{header};
    my ( @spans, @codes );
    for my $index ( 0 .. $#expressions ) {
        my ( $head, $before, $expression, $after ) = _package( $index, $context, $expressions[$index] );
        $text .= $head;
        push @codes, length $text;
        $text .= $before;
        push @spans, [ length $text, length($text) + length $expression ];
        $text .= $expression . $after;
    }
    $text .= "1;\n" if !$context->{last};
    return { text => $text, spans => \@spans, codes => \@codes };
}

# The mutants that change a part of an expression, each by its place in the expression.
# A mutant of the whole expression belongs to the context: a return value, a condition, or a statement.
sub inside ( $mutants, $span ) {
    my ( $from, $to ) = $span->@*;
    my @parts = grep     { $_->start >= $from && $_->end <= $to && $_->end - $_->start != $to - $from } $mutants->@*;
    my @named = sort map { join q{ }, $_->start - $from, $_->original, '->', $_->replacement, $_->mutator } @parts;
    return @named;
}

sub _expression_mutants ( $context, $expression ) {
    my $file = file( $context, $expression );
    my $made = Oracle::generated( Oracle::text_source( 'snippet', $file->{text} ) );
    return [ inside( $made->{mutants}, $file->{spans}[0] ) ];
}

# What a context does to the mutants of an expression, beside the context that assigns the expression to a variable.
# A line with a minus names a mutant that the context loses, and a line with a plus names one that it adds.
sub lost ( $context, $expression ) {
    my %here  = map { $_ => 1 } _expression_mutants( $context,                               $expression )->@*;
    my %there = map { $_ => 1 } _expression_mutants( { header => $KNOWN, $CONTEXTS[0]->%* }, $expression )->@*;
    my @lines =
      ( ( map { "- $_" } grep { !$here{$_} } keys %there ), ( map { "+ $_" } grep { !$there{$_} } keys %here ) );
    return [ sort @lines ];
}

# The snippets of a list of tuples: the operator, both operands, and the context of each tuple.
sub chosen (@tuples) {
    my @operators = operators();
    my @operands  = operands();
    my @contexts  = contexts();
    my @snippets;
    for my $tuple (@tuples) {
        my ( $operator, $before, $after, $context ) = $tuple->@*;
        push @snippets,
          {
            context    => $contexts[$context],
            expression => expression( $operators[$operator], $operands[$before], $operands[$after] ),
            shape      => "$operands[$before]{name}, $operands[$after]{name}",
          };
    }
    return @snippets;
}

sub _snippet_records ( $judge, $snippet ) {
    my ( $context, $expression ) = $snippet->@{qw(context expression)};
    my $file     = file( $context, $expression );
    my $source   = Oracle::text_source( "$context->{name}: $expression->{text}", $file->{text} );
    my $bytes    = $source->to_bytes( $file->{text} );
    my $original = Judge::compiled( $judge, $bytes, 'calls' );
    return [ 'snippet', 'refused' ] if !$original->{compiled};
    my @wants = ( 'calls', $context->{loads} && Judge::loaded( $judge, $bytes )->{loaded} ? 'load' : () );
    my $made  = Oracle::generated($source);
    return [ 'snippet', 'compiled' ], [ 'problem', 'analysis', $made->{problem}, $made->{detail} ]
      if defined $made->{problem};

    # The lines before the code of the context are the same in every snippet, and so are their mutants.
    $made->{mutants} = [ grep { $_->start >= $file->{codes}[0] } $made->{mutants}->@* ];
    my $judgement = Oracle::judged_by( $judge, $source, $made->{mutants}, $original, @wants );
    my @changes   = lost( $context, $expression )->@*;
    my $changed   = "the context changes the mutants of an expression: $context->{name}";
    return (
        [ 'snippet', 'compiled' ],
        Oracle::text_records( $source, $made ),
        Oracle::judged_records( $source, $judgement, @wants ),

        # A snippet loads no module, so a cold perl confirms the mutants that perl stops and no sample of the others.
        Oracle::crossed_records( $source, $judgement, accepted => 0 ),
        @changes ? [ 'finding', 'context', $changed, "$expression->{text} ($snippet->{shape}): @changes" ] : (),
    );
}

# The records of one share of the snippets, from one server that compiles every snippet and every mutant of the share.
sub _share_records ( $snippets, $share, $shares ) {
    my $judge = Judge::start();
    my @records =
      map { _snippet_records( $judge, $snippets->[$_] ) } grep { $_ % $shares == $share } 0 .. $snippets->$#*;
    Judge::stop($judge) or die "the judge of a share of snippets ended badly\n";
    return @records;
}

# Every snippet through perl and through the oracles, as the summary of a walk with the count of the snippets beside it.
sub surveyed ( $snippets, $workers ) {
    my $shares  = 4 * $workers;
    my $records = Oracle::each_file( [ map { [ "share $_", $_, $shares ] } 0 .. $shares - 1 ],
        $workers, sub ( $name, $share, $of ) { return _share_records( $snippets, $share, $of ) } );
    my %count;
    $count{ $_->[2] }++ for grep { $_->[1] eq 'snippet' } $records->@*;
    my $summary = Oracle::summary( [ grep { $_->[1] ne 'snippet' } $records->@* ] );
    $summary->{snippets} = \%count;
    return $summary;
}

1;
