package Permutl::Mutator::Catalog;
use v5.36;
use Types::Standard qw(ArrayRef Enum InstanceOf Str);
use Type::Params    qw(signature_for);
use Permutl::Mutator;

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
        table       => { '&&' => ['||'], '||' => ['&&'], 'and' => ['or'], 'or' => ['and'], '//' => ['||'] },
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
        name        => 'conditional-keyword',
        profile     => 'default',
        description => 'Swaps a conditional keyword with its negation',
        roles       => [ 'compound', 'modifier' ],
        table       => { if => 'unless', unless => 'if', while => 'until', until => 'while' },
    },
    {
        name        => 'loop-control',
        profile     => 'default',
        description => 'Swaps last and next',
        roles       => ['control'],
        table       => { last => 'next', next => 'last' },
    },
    {
        name        => 'call-swap',
        profile     => 'default',
        description => 'Replaces a function with its counterpart',
        roles       => ['call'],
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
        table       => { true => 'false', false => 'true' },
    },
    {
        name        => 'shift-pop',
        profile     => 'extended',
        description => 'Swaps shift and pop',
        roles       => ['call'],
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
    my ( $role, $table ) = $family->@{qw(role table)};
    my $idle     = $family->{idle}     || {};
    my $boundary = $family->{boundary} || {};
    return Permutl::Mutator->new(
        name        => $family->{name},
        profile     => 'default',
        description => $family->{description},
        generate    => sub ($site) {
            return if $site->kind ne 'operator' || $site->role ne $role;
            my $text         = $site->text;
            my $replacements = $table->{$text} or return;
            my $operand      = $site->detail->{right};
            return if defined $operand && defined $idle->{$text} && $operand == $idle->{$text};

            # A settled comparison gives the same result on both sides of its boundary.
            my $settled = $site->detail->{settled} ? $boundary->{$text} : q{};
            return map { { replacement => $_, description => "replaced $text with $_" } }
              grep { $_ ne $settled } $replacements->@*;
        },
    );
}

sub _word_mutator ($family) {
    my %role  = map { $_ => 1 } $family->{roles}->@*;
    my $table = $family->{table};
    return Permutl::Mutator->new(
        name        => $family->{name},
        profile     => $family->{profile},
        description => $family->{description},
        generate    => sub ($site) {
            return if $site->kind ne 'word' || !$role{ $site->role };
            my $text        = $site->text;
            my $replacement = $table->{$text};
            return if !defined $replacement;
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

sub _match ($site) {
    return if $site->kind ne 'operator' || $site->role ne 'binary';
    my $text = $site->text;
    return if $text ne '=~' && $text ne '!~';
    my $operand = $site->detail->{operand};
    return if !defined $operand || $operand ne 'match';
    my $replacement = $text eq '=~' ? '!~' : '=~';
    return { replacement => $replacement, description => "replaced $text with $replacement" };
}

sub _return_value ($site) {
    return if $site->kind ne 'return';
    my $literal = $site->detail->{literal};
    return { replacement => '0', description => 'replaced return 1 with return 0' }
      if defined $literal && $literal eq '1';
    return { replacement => '1', description => 'replaced return 0 with return 1' }
      if defined $literal && $literal eq '0';
    return { replacement => _blank( $site->text ), description => 'removed the return value' };
}

sub _statement_removal ($site) {
    return if $site->kind ne 'statement';
    return { replacement => _blank( $site->text ), description => 'removed the statement' };
}

sub _sub_body ($site) {
    return if $site->kind ne 'sub_body';
    my $name = $site->detail->{name};
    return { replacement => _blank( $site->text ), description => "removed the body of $name" };
}

sub _number_literal ($site) {
    return if $site->kind ne 'number';
    my $text = $site->text;
    return if $text !~ /\A[0-9]+\z/;
    my $replacement = $text eq '0' ? '1' : $text eq '1' ? '0' : $text + 1;
    return { replacement => "$replacement", description => "replaced $text with $replacement" };
}

sub _string_literal ($site) {
    return if $site->kind ne 'string';
    my $text  = $site->text;
    my $quote = substr $text, 0, 1;
    return if $quote ne q{'} && $quote ne q{"};
    return if length $text < 2 || substr( $text, -1 ) ne $quote;
    return { replacement => $quote . 'permutl' . $quote, description => 'replaced the empty string' }
      if length $text == 2;
    return { replacement => $quote . $quote, description => 'emptied the string' };
}

sub _condition_fixed ($site) {
    return if $site->kind ne 'condition';
    my $keyword = $site->detail->{keyword};
    my @values  = $keyword eq 'while' ? ('0') : $keyword eq 'until' ? ('1') : ( '1', '0' );
    return map { { replacement => $_, description => "replaced the $keyword condition with $_" } } @values;
}

sub _range_boundary ($site) {
    return if $site->kind ne 'operator' || $site->role ne 'binary' || $site->text ne '..';
    return { replacement => '.. -1 +', description => 'lowered the upper bound of the range by one' };
}

sub _regex_anchor ($site) {
    return if $site->kind ne 'regex' || $site->role ne 'anchor';
    return { replacement => q{}, description => 'removed the anchor ' . $site->text };
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
    [ 'negation',          'default',  'Removes a logical negation',                       \&_negation ],
    [ 'match',             'default',  'Negates a pattern match',                          \&_match ],
    [ 'return-value',      'default',  'Removes a return value or flips a literal 0 or 1', \&_return_value ],
    [ 'statement-removal', 'default',  'Removes an expression statement',                  \&_statement_removal ],
    [ 'sub-body',          'default',  'Removes the body of a subroutine',                 \&_sub_body ],
    [ 'number-literal',    'extended', 'Changes an integer literal',                       \&_number_literal ],
    [ 'string-literal',    'extended', 'Empties a string literal',                         \&_string_literal ],
    [ 'condition-fixed',   'extended', 'Replaces a condition with a constant',             \&_condition_fixed ],
    [ 'range-boundary',    'extended', 'Lowers the upper bound of a range by one',         \&_range_boundary ],
    [ 'regex-anchor',      'extended', 'Removes an anchor from a pattern',                 \&_regex_anchor ],
    [ 'regex-quantifier',  'extended', 'Changes a quantifier in a pattern',                \&_regex_quantifier ],
    [ 'regex-flag',        'extended', 'Removes the case flag from a pattern',             \&_regex_flag ],
);

my @ALL = (
    ( map { _operator_mutator($_) } @OPERATOR_FAMILIES ),
    ( map { _word_mutator($_) } @WORD_FAMILIES ),
    (
        map {
            Permutl::Mutator->new( name => $_->[0], profile => $_->[1], description => $_->[2], generate => $_->[3] )
        } @CODED
    ),
);

signature_for mutators => ( positional => [], returns => ArrayRef [ InstanceOf ['Permutl::Mutator'] ] );

sub mutators () {
    return [@ALL];
}

signature_for choose => (
    named   => [ profile => Enum [qw(default extended)], enable => ArrayRef [Str], disable => ArrayRef [Str] ],
    returns => ArrayRef [ InstanceOf ['Permutl::Mutator'] ],
);

sub choose ($arg) {
    my %known   = map  { $_->name => 1 } @ALL;
    my @unknown = grep { !$known{$_} } $arg->enable->@*, $arg->disable->@*;
    die 'unknown mutator: ' . join( ', ', @unknown ) . "\n" if @unknown;

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

Permutl::Mutator::Catalog - the built-in mutators

=head1 SYNOPSIS

    my $mutators = Permutl::Mutator::Catalog::choose(
        profile => 'default',
        enable  => ['number-literal'],
        disable => ['sub-body'],
    );

=head1 DESCRIPTION

C<permutl mutators> prints the name, the profile, and the description of every mutator.

The C<arithmetic> mutator leaves C<+ 0>, C<- 0>, C<* 1>, C</ 1>, and C<** 1> alone.
The operator and its replacement give the same value there, apart from the sign of a negative zero under C<* 1> and C</ 1>.

The C<comparison> mutator keeps the boundary of a comparison between C<$]> and a number, as in C<< $] < 5.010 >>.
The boundary matters on the one interpreter whose version equals the number, and the tests of other interpreters cannot detect its change.
The negation of such a comparison stays a mutant.

=head1 FUNCTIONS

=head2 mutators

Returns every built-in mutator.

=head2 choose

Returns the mutators of a profile, plus the enabled names and minus the disabled names.
The C<extended> profile includes the C<default> mutators.
An unknown name is a fatal error.

=cut
