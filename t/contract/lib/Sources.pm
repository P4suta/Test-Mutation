package Sources;
use v5.36;
use PPI;

# What the source text of the library says: its messages, its lists of statuses, its variables of the environment,
# and its documentation.
# Each reader takes the text of one file, so a test feeds it a broken text and sees what it finds.

sub slurp ($path) {
    open my $handle, '<:encoding(UTF-8)', $path or die "read $path: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return $text;
}

sub _document ($code) {
    return PPI::Document->new( \$code, feature_mods => { signatures => 1 } ) || die "the code does not parse\n";
}

# A message as its fixed words, with a mark where the code puts a value.
my $VALUE    = "\x{2026}";
my $VARIABLE = qr/[\$\@](?:\{[^}]*\}|[[:alpha:]_]\w*(?:::\w+)*(?:(?:->)?(?:\[[^\]]*\]|\{[^}]*\}))*|[!\@&0-9])/;

sub _fixed ($token) {
    return $token->string if $token->isa('PPI::Token::Quote::Single') || $token->isa('PPI::Token::Quote::Literal');
    return $token->string =~ s/$VARIABLE/$VALUE/gr =~ s/\\n/\n/gr;
}

# The tokens of the message that follows a reporter: the last argument of a call, or the words up to the end of the statement.
sub _message_tokens ($word) {
    my $next = $word->snext_sibling or return;
    if ( $next->isa('PPI::Structure::List') ) {
        my @groups = ( [] );
        for my $token ( map { $_->schildren } $next->schildren ) {
            my $comma = $token->isa('PPI::Token::Operator') && $token->content eq q{,};
            $comma ? push @groups, [] : push $groups[-1]->@*, $token;
        }
        return $groups[-1]->@*;
    }
    my @tokens;
    for ( my $token = $next ; $token ; $token = $token->snext_sibling ) {
        last if $token->isa('PPI::Token::Structure') && $token->content eq q{;};
        last if $token->isa('PPI::Token::Word')      && $token->content =~ /\A(?:if|unless|for|foreach)\z/;
        push @tokens, $token;
    }
    return @tokens;
}

# A message with words of its own, and nothing for an error that the code only passes on.
sub _template ($word) {
    my @parts = map { $_->isa('PPI::Token::Quote') ? _fixed($_) : $VALUE }
      grep { !$_->isa('PPI::Token::Operator') } _message_tokens($word);
    my $text = join( q{}, @parts ) =~ s/\n+\z//r =~ s/(?:\Q$VALUE\E)+/$VALUE/gr;
    return $text =~ /[[:alpha:]]{2}/ ? $text : ();
}

# The subroutines that take the identifier of a message of the catalog as their first argument.
my %NAMES_A_MESSAGE = map { $_ => 1 }
  qw(Test::Mutation::Error::raise Test::Mutation::Message::text_of Test::Mutation::Message::row Test::Mutation::Message::warning);

# The first argument of every call that names a message: the identifier, or a mark for a value that the code computes.
sub identifiers ($code) {
    my $document = _document($code);
    my @named;
    for my $word ( grep { $NAMES_A_MESSAGE{ $_->content } } @{ $document->find('PPI::Token::Word') || [] } ) {
        my $list = $word->snext_sibling;
        next if !$list || !$list->isa('PPI::Structure::List');
        my ($first) = map { $_->schildren } $list->schildren;
        my $literal =
          $first && ( $first->isa('PPI::Token::Quote::Single') || $first->isa('PPI::Token::Quote::Literal') );
        push @named, $literal ? $first->string : 'a-computed-identifier';
    }
    return \@named;
}

# The number of places where the code catches an exception itself.
sub evals ($code) {
    my $document = _document($code);
    return scalar grep {
        my ( $before, $after ) = ( $_->sprevious_sibling, $_->snext_sibling );
        $_->content eq 'eval' && !( $after && $after->content eq '=>' ) && !( $before && $before->content eq '->' )
    } @{ $document->find('PPI::Token::Word') || [] };
}

# The messages that the code raises with `die` and its kin, and the ones that it hands to the named subroutines.
sub messages ( $code, @reporters ) {
    my %reporter = map { $_ => 1 } qw(die croak confess), @reporters;

    # The document owns its elements, so it stays in scope while the scan reads them.
    my $document = _document($code);
    my @words    = grep { $reporter{ $_->content } } @{ $document->find('PPI::Token::Word') || [] };

    # A name before a fat comma or behind an arrow is a key or a method, and `sub` before it defines the reporter.
    my @calls = grep {
        my ( $before, $after ) = ( $_->sprevious_sibling, $_->snext_sibling );
        !( $after && $after->content eq '=>' ) && !( $before && $before->content =~ /\A(?:->|sub)\z/ )
    } @words;
    return [ grep { defined } map { _template($_) } @calls ];
}

# A regular expression for the text of a message, from its fixed words.
sub pattern ($message) {
    my $pattern = join '.*', map { quotemeta } split /\Q$VALUE\E/, $message, -1;
    return qr/\A$pattern\z/s;
}

# What a statement holds itself: its elements of one class, without the ones inside a block of its own.
# The statements of a subroutine or of a branch stand in a block, and each of them answers for itself.
sub _own ( $statement, $wanted ) {
    return @{
        $statement->find(
            sub ( $top, $element ) {
                return undef if $element->isa('PPI::Structure::Block');    ## no critic (Subroutines::ProhibitExplicitReturnUndef)
                return $wanted->($element) ? 1 : 0;
            }
          )
          || []
    };
}

# A name stands in a list where it is a word of a word list, a key before a fat comma, or a key of a subscript.
# A name that the code returns, compares, or stores is a use of one status, and a decision between two of them is no list.
sub _listed ($token) {
    return 1 if $token->isa('PPI::Token::QuoteLike::Words');
    return 0 if !$token->isa('PPI::Token::Word') && !$token->isa('PPI::Token::Quote');
    my $next = $token->snext_sibling;
    return 1 if $next && $next->isa('PPI::Token::Operator') && $next->content eq '=>';
    my $holder = $token->parent;
    $holder = $holder->parent if $holder && $holder->isa('PPI::Statement::Expression');
    return $holder && $holder->isa('PPI::Structure::Subscript') ? 1 : 0;
}

sub _names_in ( $statement, $known ) {
    my @tokens = _own( $statement, \&_listed );
    my %found;
    for my $token (@tokens) {
        my @texts =
            $token->isa('PPI::Token::QuoteLike::Words') ? $token->literal
          : $token->isa('PPI::Token::Quote')            ? $token->string
          :                                               $token->content;
        $found{$_} = 1 for grep { $known->{$_} } @texts;
    }
    return keys %found;
}

# The number of statements that hold two or more names of a list, such as the statuses, each counted at its innermost.
sub lists_of ( $code, $names ) {
    my %known      = map { $_ => 1 } $names->@*;
    my $document   = _document($code);
    my @statements = @{ $document->find('PPI::Statement') || [] };
    my @holding    = grep { _names_in( $_, \%known ) > 1 } @statements;
    my %holding    = map  { $_->refaddr => 1 } @holding;
    return scalar grep {
        !_own( $_, sub ($element) { return $element->isa('PPI::Statement') && $holding{ $element->refaddr } } )
    } @holding;
}

my $ENVIRONMENT_NAME = qr/[[:upper:]][[:upper:][:digit:]_]*/;

sub _environment_name ($subscript) {
    my ($name) = $subscript =~ /\A['"]?($ENVIRONMENT_NAME)['"]?\z/;
    return defined $name ? $name : 'a-computed-name';
}

# The names of the environment that the code reads or sets, with a mark for a name that the code computes.
sub environment ($code) {
    my $document = _document($code);
    $document->prune('PPI::Token::Comment');
    $document->prune('PPI::Token::Pod');
    my $text       = $document->serialize =~ s/^__END__\n.*//msr;
    my @subscripts = $text                =~ /\$ENV\{\s*([^}]*?)\s*\}/g;
    my @of_a_world = $text                =~ /(?:\$env|\{env\})(?:->)?\{($ENVIRONMENT_NAME)\}/g;
    my %name       = map { $_ => 1 } @of_a_world, map { _environment_name($_) } @subscripts;
    return [ sort keys %name ];
}

# The documentation of a file: its text, its verbatim paragraphs without their indent, and the texts of its code references.
sub documentation ($text) {
    my $document = PPI::Document->new( \$text ) || die "the text does not parse\n";
    my @pod      = map { $_->content } @{ $document->find('PPI::Token::Pod') || [] };
    my ( @blocks, @references );
    for my $paragraph ( map { split /\n{2,}/ } @pod ) {
        if ( $paragraph =~ /\A[ \t]/ ) {
            push @blocks, $paragraph =~ s/^[ ]{4}//mgr;
            next;
        }
        push @references, map { s/\A\s+|\s+\z//gr } grep { defined } $paragraph =~ /C<<\s+(.+?)\s+>>|C<([^<>]+)>/g;
    }
    return { text => join( q{}, @pod ), blocks => \@blocks, references => \@references };
}

1;
