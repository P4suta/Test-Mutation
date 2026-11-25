use v5.36;
use Test2::V0;
use B::Deparse ();
use Test::Mutation::Syntax::Precedence;

# The table of precedence sorts the functions of perl into named unary operators, list operators, and terms.
# Perl itself decides how far the operand of each one reaches, and B::Deparse prints its reading with parentheses.

my $deparse = B::Deparse->new('-p');

# The reading of a line of code, or the error of perl.
sub reading ($code) {
    my $compiled = eval "no strict; no warnings; use feature qw(fc say evalbytes current_sub); sub { $code }";    ## no critic (BuiltinFunctions::ProhibitStringyEval)
    return $compiled ? $deparse->coderef2text($compiled) : "error: $@";
}

my @levels = Test::Mutation::Syntax::Precedence::levels()->@*;
my ($named) = grep {
    grep { $_ eq 'defined' }
      $_->{prefix}->@*
} @levels;
my ($listed) = grep {
    grep { $_ eq 'print' }
      $_->{prefix}->@*
} @levels;

# A few functions compile with an element of a hash, a hash, or an array alone.
my %OPERAND = (
    ( map { $_ => '$h{$a}' } qw(exists delete) ),
    ( map { $_ => '%h' } qw(each keys values dbmclose) ),
    ( map { $_ => '@a' } qw(pop shift) ),
);

my @named = grep { !/\A-/ } $named->{prefix}->@*;
for my $word (@named) {
    my $operand = $OPERAND{$word} || '$a';
    my $text    = reading("\$r = $word $operand < \$b, \$c;");
    ok !holds( $text, "($operand < \$b)" ), "$word takes the operand alone";
    unlike $text, qr/\Aerror/, "and perl compiles it ($word)";
}

# A list operator with a prototype in the core gets an operand for each place of its prototype.
# A place for an array, a hash, or a reference gets one, and the first other place gets the comparison.
my %OF_PLACE = ( '\@' => '@a', '\%' => '%h', '\[$@%*]' => '$x' );
for my $word ( $listed->{prefix}->@* ) {
    my $prototype = prototype "CORE::$word";
    my @places    = ( defined $prototype ? $prototype : '$' ) =~ /\\[@%]|\\\[[^]]*\]|[\$*@%&_]/g;
    my $compared  = 0;
    my @operands  = map { $OF_PLACE{$_} || ( $compared++ ? "\$c$compared" : '$a < $b' ) } @places;
    my $text      = reading( "\$r = $word " . join( ', ', @operands ) . ';' );
    ok holds( $text, '($a < $b)' ), "$word takes the comparison as its operand";
}

# Perl compiles __CLASS__ inside a method of a class alone.
for my $word ( grep { $_ ne '__CLASS__' } Test::Mutation::Syntax::Precedence::terms()->@* ) {
    my $text = reading("\$r = $word + 1;");
    ok !holds( $text, "$word(" ), "$word takes no operand";
    unlike $text, qr/\Aerror/, "and perl compiles it ($word)";
}

for my $test ( grep { /\A-/ } $named->{prefix}->@* ) {
    my $text = reading("\$r = $test \$a . \$b || \$c;");
    ok holds( $text, '($a . $b)) || $c' ), "the file test $test takes a concatenation and leaves a logical or";
}

sub holds ( $text, $part ) {
    return index( $text, $part ) >= 0;
}

is scalar(@named),                  84, 'the named unary operators of perlfunc';
is scalar( $listed->{prefix}->@* ), 88, 'and its list operators';

done_testing;
