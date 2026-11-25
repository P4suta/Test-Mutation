package Test::Mutation::Mutator::Catalog;
use v5.36;
use Types::Standard qw(ArrayRef Enum InstanceOf Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Mutator;

our $VERSION = '0.001';

my @OPERATOR_FAMILIES = (
    {
        name        => 'arithmetic',
        description => 'Replaces an arithmetic operator with its counterpart',
        role        => 'binary',
        table       => { '+' => ['-'], '-' => ['+'], '*' => ['/'], '/' => ['*'], '%'  => ['*'], '**' => ['*'] },
        idle        => { '+' => 0,     '-' => 0,     '*' => 1,     '/' => 1,     '**' => 1 },
    },
    {
        name        => 'comparison',
        description => 'Moves the boundary of a numeric comparison or negates it',
        role        => 'binary',
        table       => {
            '<'  => [ '<=', '>=' ],
            '<=' => [ '<',  '>' ],
            '>'  => [ '>=', '<=' ],
            '>=' => [ '>',  '<' ],
            '==' => ['!='],
            '!=' => ['=='],
        },
        boundary => { '<' => '<=', '<=' => '<', '>' => '>=', '>=' => '>' },
    },
    {
        name        => 'string-comparison',
        description => 'Moves the boundary of a string comparison or negates it',
        role        => 'binary',
        table       => {
            lt => [ 'le', 'ge' ],
            le => [ 'lt', 'gt' ],
            gt => [ 'ge', 'le' ],
            ge => [ 'gt', 'lt' ],
            eq => ['ne'],
            ne => ['eq'],
        },
    },
    {
        name        => 'logical',
        description => 'Replaces a logical operator with its counterpart',
        role        => 'binary',
        table       => {
            '&&'  => ['||'],
            '||'  => ['&&'],
            'and' => ['or'],
            'or'  => ['and'],
            '//'  => ['||'],
            'xor' => ['or'],
            '^^'  => ['||'],
        },
    },
    {
        name        => 'bitwise',
        description => 'Replaces a bitwise operator with its counterpart or removes a complement',
        role        => 'binary',
        table       => {
            q{&}  => [q{|}],
            q{|}  => [q{&}],
            q{^}  => [q{&}],
            '<<'  => ['>>'],
            '>>'  => ['<<'],
            '&.'  => ['|.'],
            '|.'  => ['&.'],
            '^.'  => ['&.'],
            '&='  => ['|='],
            '|='  => ['&='],
            '^='  => ['&='],
            '<<=' => ['>>='],
            '>>=' => ['<<='],
            '&.=' => ['|.='],
            '|.=' => ['&.='],
            '^.=' => ['&.='],
        },
        unary => { q{~} => [q{}], '~.' => [q{}] },
        idle  => { '<<' => 0,     '>>' => 0 },
    },
    {
        name        => 'increment',
        description => 'Swaps increment and decrement',
        role        => 'update',
        table       => { '++' => ['--'], '--' => ['++'] },
    },
    {
        name        => 'assignment',
        description => 'Replaces a compound assignment with its counterpart',
        role        => 'binary',
        table       => {
            '+='  => ['-='],
            '-='  => ['+='],
            '*='  => ['/='],
            '/='  => ['*='],
            '%='  => ['*='],
            '**=' => ['*='],
            '.='  => ['='],
            '||=' => ['&&='],
            '&&=' => ['||='],
            '//=' => ['||='],
        },
    },
);

my @WORD_FAMILIES = (
    {
        name        => 'loop-control',
        profile     => 'default',
        description => 'Swaps last and next, and turns redo into next',
        roles       => ['control'],
        table       => { last => 'next', next => 'last', redo => 'next' },
    },
    {
        name        => 'call-swap',
        profile     => 'default',
        description => 'Replaces a function with its counterpart',
        roles       => ['call'],
        calls       => 1,
        table       => {
            min     => 'max',
            max     => 'min',
            minstr  => 'maxstr',
            maxstr  => 'minstr',
            any     => 'all',
            all     => 'any',
            none    => 'any',
            notall  => 'all',
            push    => 'unshift',
            unshift => 'push',
            lc      => 'uc',
            uc      => 'lc',
            lcfirst => 'ucfirst',
            ucfirst => 'lcfirst',
            index   => 'rindex',
            rindex  => 'index',
            ceil    => 'floor',
            floor   => 'ceil',
        },
    },
    {
        name        => 'boolean-literal',
        profile     => 'default',
        description => 'Swaps true and false',
        roles       => ['call'],
        calls       => 1,
        table       => { true => 'false', false => 'true' },
    },
    {
        name        => 'shift-pop',
        profile     => 'extended',
        description => 'Swaps shift and pop',
        roles       => ['call'],
        calls       => 1,
        table       => { shift => 'pop', pop => 'shift' },
    },
    {
        name        => 'sort-order',
        profile     => 'extended',
        description => 'Reverses the result of a sort',
        roles       => ['call'],
        table       => { sort => 'reverse sort' },
    },
);

sub _blank ($text) {
    return join q{}, $text =~ /\n/g;
}

# An operand in the idle table leaves the value as it is under the operator and under its replacement.
# Zero added or subtracted never differs, and neither does one as an exponent.
# One as a factor differs from one as a divisor for negative zero alone.
sub _operator_mutator ($family) {
    my %tables   = ( $family->{role} => $family->{table}, unary => $family->{unary} || {} );
    my $idle     = $family->{idle}     || {};
    my $boundary = $family->{boundary} || {};
    return Test::Mutation::Mutator->new(
        name        => $family->{name},
        profile     => 'default',
        description => $family->{description},
        generate    => sub ($site) {
            return if $site->kind ne 'operator';
            my $table        = $tables{ $site->role } or return;
            my $text         = $site->text;
            my $replacements = $table->{$text} or return;
            my $operand      = $site->facts->{right};
            return if defined $operand && defined $idle->{$text} && $operand == $idle->{$text};

            # A settled comparison gives the same result on both sides of its boundary.
            my $settled = $site->facts->{settled} ? $boundary->{$text} : undef;
            return map {
                {
                    replacement => $site->facts->{implicit_call} && /\A</ ? "() $_"                  : $_,
                    description => $_ ne q{}                              ? "replaced $text with $_" : "removed $text",
                }
              }
              grep { !defined $settled || $_ ne $settled } $replacements->@*;
        },
    );
}

sub _word_mutator ($family) {
    my %role  = map { $_ => 1 } $family->{roles}->@*;
    my $table = $family->{table};
    return Test::Mutation::Mutator->new(
        name        => $family->{name},
        profile     => $family->{profile},
        description => $family->{description},
        generate    => sub ($site) {
            return if $site->kind ne 'word' || !$role{ $site->role };
            my $text = $site->text;

            # A function may stand under its qualified name, and the table knows it by its own name.
            # The generator writes the name of the counterpart as the file resolves it.
            my $word        = $family->{calls} ? $text =~ s/\A.*:://r : $text;
            my $replacement = $table->{$word};
            return if !defined $replacement;
            return { replacement => $replacement, description => "replaced $text with %s", calls => $replacement }
              if $family->{calls};
            return { replacement => $replacement, description => "replaced $text with $replacement" };
        },
    );
}

sub _negation ($site) {
    return if $site->kind ne 'operator' || $site->role ne 'unary';
    my $text = $site->text;
    return if $text ne q{!} && $text ne 'not';
    return { replacement => q{}, description => "removed $text" };
}

sub _unary_minus ($site) {
    my $text = $site->text;
    return { replacement => q{}, description => 'removed the unary minus' }
      if $site->kind eq 'operator' && $site->role eq 'unary' && $text eq q{-};
    return if $site->kind ne 'number';
    my ($unsigned) = $text =~ /\A-(.+)\z/s or return;
    return { replacement => $unsigned, description => "replaced $text with $unsigned" };
}

my %NEGATED_KEYWORD = ( if => 'unless', unless => 'if', while => 'until', until => 'while' );

# A keyword turns into its negation, and an elsif has none, so its condition is negated.
# The condition of a conditional operator has no left edge that the analysis can name, so its branches swap.
sub _condition_negation ($site) {
    my ( $kind, $text, $facts ) = ( $site->kind, $site->text, $site->facts );
    if ( $kind eq 'word' && ( $site->role eq 'compound' || $site->role eq 'modifier' ) ) {
        my $negation = $NEGATED_KEYWORD{$text} or return;
        return { replacement => $negation, description => "replaced $text with $negation" };
    }
    if ( $kind eq 'condition' && defined $facts->{keyword} && $facts->{keyword} eq 'elsif' ) {
        return { replacement => "!($text)", description => 'negated the elsif condition' };
    }
    return if $kind ne 'branches' || !$facts->{branches};
    my ( $first, $later ) = $facts->{branches}->@*;
    my $moved   = $facts->{loose} ? '(' . substr( $text, 0, $first ) . ')' : substr $text, 0, $first;
    my $swapped = substr( $text, $later ) . substr( $text, $first, $later - $first ) . $moved;
    return { replacement => $swapped, description => 'swapped the branches of the conditional' };
}

# A test of definedness, of existence, of the context of a call, or of a file turns into its negation.
my %PREDICATE = map { $_ => 1 } qw(defined exists wantarray);

sub _predicate ($site) {
    my $text = $site->text;
    my $word = $site->kind eq 'word'     && $site->role eq 'call'  && $PREDICATE{ $text =~ s/\ACORE:://r };
    my $file = $site->kind eq 'operator' && $site->role eq 'unary' && $text =~ /\A-[[:alpha:]]\z/;
    return if !$word && !$file;
    return { replacement => "!$text", description => "negated $text" };
}

sub _match ($site) {
    return if $site->kind ne 'operator' || $site->role ne 'binary';
    my $text = $site->text;
    return if $text ne '=~' && $text ne '!~';
    my $operand = $site->facts->{operand};
    return if !defined $operand || $operand ne 'match';
    my $replacement = $text eq '=~' ? '!~' : '=~';
    return { replacement => $replacement, description => "replaced $text with $replacement" };
}

sub _return_value ($site) {
    return if $site->kind ne 'return';
    my $literal = $site->facts->{literal};
    return { replacement => '0', description => 'replaced return 1 with return 0' }
      if defined $literal && $literal eq '1';
    return { replacement => '1', description => 'replaced return 0 with return 1' }
      if defined $literal && $literal eq '0';
    return { replacement => _blank( $site->text ), description => 'removed the return value' };
}

# A lexical handle closes at the end of its scope, so few test suites detect a missing close.
my %CLOSES = map { $_ => 1 } qw(close closedir CORE::close CORE::closedir);

sub _closes ($site) {
    my $head = $site->facts->{head};
    return defined $head && $CLOSES{$head} ? 1 : 0;
}

sub _statement_removal ($site) {
    return if $site->kind ne 'statement' || _closes($site);
    return { replacement => _blank( $site->text ), description => 'removed the statement' };
}

sub _close_removal ($site) {
    return if $site->kind ne 'statement' || !_closes($site);
    return { replacement => _blank( $site->text ), description => 'removed the statement' };
}

sub _sub_body ($site) {
    return if $site->kind ne 'sub_body';
    my $name = $site->facts->{name};
    return { replacement => _blank( $site->text ), description => "removed the body of $name" };
}

sub _number_literal ($site) {
    return if $site->kind ne 'number';
    my $text = $site->text;
    return if $text !~ /\A[0-9]+\z/;
    my $replacement = $text eq '0' ? '1' : $text eq '1' ? '0' : $text + 1;
    return { replacement => "$replacement", description => "replaced $text with $replacement" };
}

# A string in quotes or under q or qq keeps its delimiters, and the text between them goes or, when empty, gets a word.
sub _string_literal ($site) {
    return if $site->kind ne 'string' || $site->role eq 'open-mode';
    my $text = $site->text;
    my ( $open, $inside, $close ) = $text =~ /\A((?:qq?\s*)?[^\w\s])(.*)([^\w\s])\z/s or return;
    return if $open =~ /\A['"]\z/ && $close ne $open;
    return { replacement => $open . 'mutant' . $close, description => 'replaced the empty string' } if $inside eq q{};
    return { replacement => $open . $close, description => 'emptied the string' };
}

sub _condition_fixed ($site) {
    return if $site->kind ne 'condition';
    my $keyword = $site->facts->{keyword};
    my @values  = $keyword eq 'while' ? ('0') : $keyword eq 'until' ? ('1') : ( '1', '0' );
    return map { { replacement => $_, description => "replaced the $keyword condition with $_" } } @values;
}

sub _range_boundary ($site) {
    return if $site->kind ne 'operator' || $site->role ne 'binary' || $site->text ne '..';
    return { replacement => '.. -1 +', description => 'lowered the upper bound of the range by one' };
}

sub _regex_anchor ($site) {
    return if $site->kind ne 'regex' || $site->role ne 'anchor';
    return {
        replacement => $site->facts->{quantified} ? '(?:)' : q{},
        description => 'removed the anchor ' . $site->text
    };
}

sub _regex_quantifier ($site) {
    return if $site->kind ne 'regex' || $site->role ne 'quantifier';
    my $text = $site->text;
    return { replacement => q{}, description => 'removed the quantifier ?' } if $text eq q{?};
    my $replacement = $text eq q{+} ? q{*} : q{+};
    return { replacement => $replacement, description => "replaced the quantifier $text with $replacement" };
}

sub _regex_flag ($site) {
    return if $site->kind ne 'regex' || $site->role ne 'flag';
    return { replacement => q{}, description => 'removed the flag i' };
}

my @CODED = (
    [ 'unary-minus', 'default', 'Removes a unary minus or the sign of a number', \&_unary_minus ],
    [
        'condition-negation',                                         'default',
        'Negates a condition or swaps the branches of a conditional', \&_condition_negation
    ],
    [ 'predicate',         'default', 'Negates a test of definedness, existence, context, or a file', \&_predicate ],
    [ 'negation',          'default', 'Removes a logical negation',                                   \&_negation ],
    [ 'match',             'default', 'Negates a pattern match',                                      \&_match ],
    [ 'return-value',      'default', 'Removes a return value or flips a literal 0 or 1',             \&_return_value ],
    [ 'statement-removal', 'default',  'Removes an expression statement',          \&_statement_removal ],
    [ 'sub-body',          'default',  'Removes the body of a subroutine',         \&_sub_body ],
    [ 'close-removal',     'extended', 'Removes a close or closedir statement',    \&_close_removal ],
    [ 'number-literal',    'extended', 'Changes an integer literal',               \&_number_literal ],
    [ 'string-literal',    'extended', 'Empties a string literal',                 \&_string_literal ],
    [ 'condition-fixed',   'extended', 'Replaces a condition with a constant',     \&_condition_fixed ],
    [ 'range-boundary',    'extended', 'Lowers the upper bound of a range by one', \&_range_boundary ],
    [ 'regex-anchor',      'extended', 'Removes an anchor from a pattern',         \&_regex_anchor ],
    [ 'regex-quantifier',  'extended', 'Changes a quantifier in a pattern',        \&_regex_quantifier ],
    [ 'regex-flag',        'extended', 'Removes the case flag from a pattern',     \&_regex_flag ],
);

my @ALL = (
    ( map { _operator_mutator($_) } @OPERATOR_FAMILIES ),
    ( map { _word_mutator($_) } @WORD_FAMILIES ),
    (
        map {
            Test::Mutation::Mutator->new(
                name        => $_->[0],
                profile     => $_->[1],
                description => $_->[2],
                generate    => $_->[3]
            )
        } @CODED
    ),
);

signature_for mutators => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Mutator'] ] );

sub mutators () {
    return [@ALL];
}

signature_for choose => (
    named   => [ profile => Enum [qw(default extended)], enable => ArrayRef [Str], disable => ArrayRef [Str] ],
    returns => ArrayRef [ InstanceOf ['Test::Mutation::Mutator'] ],
);

sub choose ($arg) {
    my %known   = map  { $_->name => 1 } @ALL;
    my @unknown = grep { !$known{$_} } $arg->enable->@*, $arg->disable->@*;
    Test::Mutation::Error::raise( 'mutator-unknown', names => join q{, }, @unknown ) if @unknown;

    my %enabled  = map { $_ => 1 } $arg->enable->@*;
    my %disabled = map { $_ => 1 } $arg->disable->@*;
    return [
        grep {
            !$disabled{ $_->name }
              && ( $enabled{ $_->name } || $_->profile eq 'default' || $arg->profile eq 'extended' )
        } @ALL
    ];
}

1;

__END__

=head1 NAME

Test::Mutation::Mutator::Catalog - the built-in mutators

=head1 SYNOPSIS

    my $mutators = Test::Mutation::Mutator::Catalog::choose(
        profile => 'default',
        enable  => ['number-literal'],
        disable => ['sub-body'],
    );

=head1 DESCRIPTION

C<mutation mutators> prints the name, the profile, and the description of every mutator.

The C<arithmetic> mutator leaves C<+ 0>, C<- 0>, C<* 1>, C</ 1>, and C<** 1> alone.
The operator and its replacement give the same value there, apart from the sign of a negative zero under C<* 1> and C</ 1>.

The C<comparison> mutator keeps the boundary of a comparison between C<$]> and a number, as in C<< $] < 5.010 >>.
The boundary matters on the one interpreter whose version equals the number, and the tests of other interpreters cannot detect its change.
The negation of such a comparison stays a mutant.

The C<logical> mutator turns the exclusive C<xor> and C<^^> into the C<or> and the C<||> of their precedence.
The C<bitwise> mutator swaps C<&> and C<|>, turns C<^> into C<&>, swaps C<<< << >>> and C<<< >> >>>, does the same to the string forms and to the assignments, and removes a complement.
The C<unary-minus> mutator removes a unary minus and the sign of a negative number.
The C<loop-control> mutator swaps C<last> and C<next> and turns C<redo> into C<next>.
A C<next> never turns into a C<redo>, which would repeat the same pass of the loop without end.

The C<condition-negation> mutator swaps C<if> and C<unless>, and C<while> and C<until>.
An C<elsif> has no such counterpart, so its condition C<C> becomes C<!(C)>.
The left edge of the condition of a conditional operator depends on every operator before it, so the mutator swaps the branches, and C<C ? A : B> becomes C<C ? B : A>.
The C<predicate> mutator negates C<defined>, C<exists>, C<wantarray>, and a file test with a C<!> before it.

The C<statement-removal> mutator leaves a C<close> or C<closedir> statement in place.
A lexical handle closes at the end of its scope, so few test suites detect the removal.
The C<close-removal> mutator of the extended profile removes those statements for a project that checks its closes.

=head1 FUNCTIONS

=head2 mutators

Returns every built-in mutator.

=head2 choose

Returns the mutators of a profile, plus the enabled names and minus the disabled names.
The C<extended> profile includes the C<default> mutators.
An unknown name is a fatal error.

=cut
