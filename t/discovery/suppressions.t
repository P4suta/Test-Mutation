use v5.36;
use Test2::V0;
use lib 't/lib';
use Gate;
use Layouts;

# The grammar of the suppression comments has a reference interpreter of its own, written from the grammar alone.
# Every layout of comments goes through the interpreter and through the parser of the tool, and each difference is a finding.

my %form = map { $_->{name} => $_ } Layouts::forms();

sub layout (@names) {
    return Layouts::rendered( map { $form{$_} || die "no form is named $_\n" } @names );
}

sub errors (@names) {
    my $layout = layout(@names);
    return Layouts::expected( $layout, Layouts::mutants($layout) )->{errors};
}

subtest 'a layout puts each comment on its own line or behind the code of its slot' => sub {
    is layout( 'block', 'line', 'end' )->{text}, <<'CODE', 'three comments around three slots and a last statement';
use strict; my ( $m, $n ) = ( 1, 2 );
## no mutate
sub s1 { return $_[0] + $_[1] }
my $v2 = $m + $n * 2;    ## no mutate
## use mutate
sub s3 { return $_[0] + $_[1] }
my $last = $m - $n * 2;
1;
CODE
    is layout( 'block', 'line', 'end' )->{comments},
      [
        { line => 2, own => 1, text => '## no mutate',  before_sub => 1 },
        { line => 4, own => 0, text => '## no mutate',  before_sub => 0 },
        { line => 5, own => 1, text => '## use mutate', before_sub => 1 },
      ],
      'each comment knows its line, its place, and whether a subroutine follows it';
};

subtest 'the interpreter rejects every layout that the grammar refuses' => sub {
    is errors(),                          [], 'no comment';
    is errors( 'block', 'end' ),          [], 'a block with its end';
    is errors('line'),                    [], 'a comment behind its code';
    is errors('named line'),              [], 'a name of a mutator';
    is errors('reason'),                  [], 'a reason after a colon';
    is errors('sub'),                     [], 'a subroutine after the comment that names one';
    is errors( 'named block', 'end' ),    [], 'a block for one mutator';
    is errors('single hash'),             ['a candidate that is not canonical'],       'one hash sign';
    is errors('other noun'),              ['a candidate that is not canonical'],       'another word after no';
    is errors('no space'),                ['a candidate that is not canonical'],       'no space after the hash signs';
    is errors('end behind code'),         ['a candidate that is not canonical'],       'an end behind code';
    is errors('unknown name'),            ['an unknown mutator name'],                 'a misspelt mutator';
    is errors('end'),                     ['a use mutate without an open block'],      'an end without a block';
    is errors( 'block', 'block', 'end' ), ['a second no mutate inside an open block'], 'a block inside a block';
    is errors('block'),                   ['a block without its use mutate'],          'a block without an end';
    is errors( 'line', 'sub' ), ['a no mutate sub without a subroutine after it'],     'a statement after the comment';
    is errors('idle name'),     ['a directive that suppresses no mutant'], 'a mutator without a mutant on the line';
    is errors( 'unknown name', 'end', 'block' ),
      [ 'an unknown mutator name', 'a use mutate without an open block', 'a block without its use mutate' ],
      'every error of a layout, in the order of the comments';
};

subtest 'the interpreter suppresses the lines that the grammar names' => sub {
    my $suppressed = sub (@names) {
        my $layout   = layout(@names);
        my @mutants  = Layouts::mutants($layout)->@*;
        my $expected = Layouts::expected( $layout, \@mutants )->{suppressed};
        my %lines    = map { $mutants[$_]{line} => 1 } grep { $expected->[$_] } 0 .. $#mutants;
        return [ sort { $a <=> $b } keys %lines ];
    };
    is $suppressed->(),                                 [],          'no comment suppresses nothing';
    is $suppressed->( 'block', 'end' ),                 [3],         'a block covers the lines up to its end';
    is $suppressed->( 'block', 'line', 'end', 'line' ), [ 3, 4, 7 ], 'a comment behind code covers its line';
    is $suppressed->('sub'),           [3],      'a comment that names a subroutine covers that subroutine';
    is $suppressed->( 'sub', 'line' ), [ 3, 4 ], 'and nothing after it';

    my $layout  = layout('named line');
    my @mutants = Layouts::mutants($layout)->@*;
    my @flags   = Layouts::expected( $layout, \@mutants )->{suppressed}->@*;
    is [ map { $mutants[$_]{mutator} } grep { $flags[$_] } 0 .. $#mutants ], ['arithmetic'],
      'a name covers the mutants of that mutator alone';
};

subtest 'the comparison rejects a parser that differs from the interpreter' => sub {
    is Layouts::differences( layout('line') ), [], 'the parser reads a comment behind code as the grammar does';
    is Layouts::differences( layout( 'block', 'end' ) ), [], 'and a block with its end';

    # The test marks the mutants by hand, so each broken reading stands here whatever the parser of the tool does.
    my $marked = sub ( $suppresses, @names ) {
        my $layout = layout(@names);
        return Layouts::differences_of( $layout, Layouts::marked( $layout, $suppresses ) );
    };
    is $marked->( sub ($mutant) { $mutant->{line} == 2 }, 'line' ), [], 'the marks of the grammar leave no difference';
    is $marked->( sub ($mutant) { 0 }, 'line' ), ['the parser suppresses other mutants than the grammar'],
      'a comment behind code that suppresses nothing';
    is $marked->( sub ($mutant) { 0 }, 'unknown name' ), ['the parser accepts an unknown mutator name'],
      'a misspelt mutator that the reader of the marks accepted';
    is $marked->( sub ($mutant) { $mutant->{line} >= 3 }, 'sub' ),
      ['the parser reads no mutate sub as the start of a block'],
      'a comment that names a subroutine and suppresses the lines after it too';
    is $marked->( sub ($mutant) { $mutant->{line} == 2 }, 'no space' ),
      [ 'the parser accepts a candidate that is not canonical', 'the parser obeys a candidate that is not canonical' ],
      'a comment without the space of the canonical form that suppresses its line';
    is $marked->( sub ($mutant) { $mutant->{line} >= 3 }, 'block', 'block', 'end' ),
      [
        'the parser accepts a second no mutate inside an open block',
        'the parser starts a second block inside an open block and never ends the first one',
      ],
      'a first block that stays open after the end of the second one';
};

my @forms     = Layouts::forms();
my @sequences = Layouts::sequences( scalar @forms, 2 );
my ( %found, $compared );
for my $sequence (@sequences) {
    my $layout = Layouts::rendered( @forms[ $sequence->@* ] );
    $compared += Layouts::mutants($layout)->@*;
    $found{$_} ||= join ' / ', map { $_->{name} } @forms[ $sequence->@* ] for Layouts::differences($layout)->@*;
}
note "$_, as in: $found{$_}" for sort keys %found;
Gate::findings( 'mutants-suppress-pairs', [ sort keys %found ] );
Gate::checked( 'forms of a comment',  scalar @forms,     at_least => 13 );
Gate::checked( 'layouts',             scalar @sequences, at_least => 183 );
Gate::checked( 'mutants of a layout', $compared,         at_least => 1500 );

done_testing;
