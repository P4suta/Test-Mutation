use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use Gate;
use Oracle;
use Test::Mutation::Mutant;
use Test::Mutation::Mutator;

# Every oracle of the mutant quality harness must refuse the defect it exists for.
# Each case below feeds one oracle a mutant or a mutator that is broken in one known way.

my $CODE = <<'CODE';
package Sample;
use strict;
use warnings;
use List::Util qw(max);

sub largest {
    my @numbers = @_;
    return max(@numbers) + 1;
}

sub twice {
    my ($n) = @_;
    return !!$n * 2;
}

1;
CODE
my $source  = Oracle::text_source( 'lib/Sample.pm', $CODE );
my $checked = 0;

sub mutator ( $name, $generate ) {
    return Test::Mutation::Mutator->new(
        name        => $name,
        profile     => 'default',
        description => 'a mutator that is broken on purpose',
        generate    => $generate,
    );
}

# A mutant that replaces the first occurrence of a text, built by hand as no mutator of the tool would build it.
sub mutant ( $original, $replacement, %override ) {
    my $start = index $CODE, $original;
    my %span  = ( start => $start, end => $start + length $original, %override );
    return Test::Mutation::Mutant->new(
        id          => sprintf( '%012x', ++$checked ),
        path        => 'lib/Sample.pm',
        mutator     => 'by-hand',
        original    => $original,
        replacement => $replacement,
        description => "replaced $original with $replacement",
        from        => $source->position_of( $span{start} ),
        to          => $source->position_of( $span{end} ),
        scope       => [ 1, 1 ],
        %span,
    );
}

sub classes (@violations) {
    return [ map { $_->[0]->mutator . q{ } . $_->[1] } @violations ];
}

subtest 'the identity oracle rejects a mutant that returns the original text' => sub {
    is classes( Oracle::unchanged( $source, [ mutant( '+', '-' ) ] ) ), [], 'a change is accepted';
    is classes( Oracle::unchanged( $source, [ mutant( '+', '+' ) ] ) ), ['by-hand leaves the text as it was'],
      'the same text is refused';
};

subtest 'the span oracle rejects a site with a shifted span' => sub {
    is classes( Oracle::misplaced( $source, [ mutant( 'max', 'min' ) ] ) ), [], 'a span on its own text is accepted';
    my $at      = index $CODE, 'max(@numbers)';
    my $shifted = mutant( 'max', 'min', start => $at + 1, end => $at + 4 );
    is classes( Oracle::misplaced( $source, [$shifted] ) ), ['by-hand names a span that holds another text'],
      'a span one character to the right is refused';
    my $beyond = mutant( 'max', 'min', start => length($CODE) - 1, end => length($CODE) + 2 );
    is classes( Oracle::misplaced( $source, [$beyond] ) ), ['by-hand names a span that holds another text'],
      'a span beyond the end of the file is refused';
    my $elsewhere = mutant( 'max', 'min', from => [ 1, 1 ] );
    is classes( Oracle::misplaced( $source, [$elsewhere] ) ), ['by-hand names a position apart from its span'],
      'a line and column apart from the offset are refused';
};

subtest 'the patch oracle rejects a patch that does not give the mutant' => sub {
    my $patch = "--- a\n+++ a\n\@\@ -2,3 +2,3 \@\@\n b\n-c\n+C\n d\n";
    is Oracle::patched( "a\nb\nc\nd\ne\n", $patch ), "a\nb\nC\nd\ne\n",      'a hunk replaces its lines';
    is Oracle::patched( "a\nb\nx\nd\ne\n", $patch ), undef,                  'a removed line that the text lacks';
    is Oracle::patched( "a\nB\nc\nd\ne\n", $patch ), undef,                  'a context line that the text lacks';
    is Oracle::patched( "a\nb\nc\n",       $patch ), undef,                  'a hunk beyond the end of the text';
    is Oracle::patched( "a\nb\nc\nd\ne\n", $patch =~ s/-2,3/-2,4/r ), undef, 'a count that the hunk does not hold';
    is Oracle::patched( "a\nb\nc\nd\ne\n", "--- a\n+++ a\n" ),        undef, 'a patch without a hunk';
    is Oracle::patched( "a\nb\nc\nd",      "--- a\n+++ a\n\@\@ -3,2 +3,2 \@\@\n c\n-d\n+D\n" ), "a\nb\nc\nD\n",
      'a patch has no way to leave the last line without its line break';

    is classes( Oracle::unpatchable( $source, [ mutant( 'max(@numbers)', 'min(@numbers)' ) ] ) ), [],
      'the patch of a mutant gives the text of the mutant';
    is classes( Oracle::unpatchable( $source, [ mutant( "return max(\@numbers) + 1;\n}\n", "\n\n" ) ] ) ), [],
      'so does the patch of a mutant over three lines';
    my $open = Oracle::text_source( 'lib/Open.pm', "my \$n = 1 + 2;\nmy \$m = \$n - 1" );
    my ($last) = grep { $_->original eq q{-} } Oracle::generated($open)->{mutants}->@*;
    is classes( Oracle::unpatchable( $open, [$last] ) ), ['arithmetic renders a patch that gives another text'],
      'the patch of a last line without a line break is refused';
};

subtest 'the uniqueness oracle rejects two mutants with one id' => sub {
    my @pair = ( mutant( '+', '-' ), mutant( '*', '/' ) );
    is classes( Oracle::repeated( $source, \@pair ) ), [], 'two changes with two ids are accepted';
    my $twin = Test::Mutation::Mutant->new(
        ( map { $_ => $pair[1]->$_ } qw(path mutator start end original) ),
        ( map { $_ => $pair[1]->$_ } qw(replacement description from to scope) ),
        id => $pair[0]->id
    );
    is classes( Oracle::repeated( $source, [ $pair[0], $twin ] ) ), ['by-hand repeats an id'],
      'one id twice is refused';

    my $first = index $CODE, '!!';
    my @bangs = map { mutant( q{!}, q{}, start => $first + $_, end => $first + $_ + 1 ) } 0, 1;
    is classes( Oracle::repeated( $source, \@bangs ) ), ['by-hand gives the same text as a mutant of by-hand'],
      'two spans that give one text are refused';
    my $wider = mutant( '!!$n', '!$n' );
    is classes( Oracle::repeated( $source, [ $bangs[1], $wider ] ) ),
      ['by-hand gives the same text as a mutant of by-hand'], 'and so is a wider span with the same result';
    is classes( Oracle::repeated( $source, [ $bangs[0], mutant( '*', '/' ) ] ) ), [], 'another result is accepted';
};

subtest 'the key of a change rejects no pair that the whole texts tell apart' => sub {
    my $text  = "aab aab\nabab\n\nxx";
    my $small = Oracle::text_source( 'lib/Small.pm', $text );
    my @edits;
    for my $start ( 0 .. length $text ) {
        for my $end ( $start .. length $text ) {
            push @edits, map { [ $start, $end, $_ ] } q{}, 'a', 'b', 'ab', 'ba', "\n", 'xa';
        }
    }
    my ( %by_key, %by_text );
    for my $edit (@edits) {
        my ( $start, $end, $replacement ) = $edit->@*;
        push $by_key{ Oracle::change_key( $text, $start, $end, $replacement ) }->@*, "$start $end $replacement";
        push $by_text{ $small->replace_span( $start, $end, $replacement ) }->@*,     "$start $end $replacement";
    }
    my $classes = sub ($groups) {
        return [ sort map { join q{|}, $_->@* } values $groups->%* ];
    };
    is $classes->( \%by_key ), $classes->( \%by_text ), 'the key groups the changes exactly as their results do';
    $checked += @edits;
};

subtest 'the compile oracle rejects a mutator that emits a closing brace' => sub {
    my $brace = mutator(
        'brace',
        sub ($site) {
            return if $site->kind ne 'operator' || $site->text ne q{+};
            return { replacement => '}', description => 'replaced + with }' };
        }
    );
    my $judgement = Oracle::judgement( $source, Oracle::generated( $source, [$brace] )->{mutants}, wants => ['calls'] );
    is $judgement->{problem}, undef, 'perl accepts the original';
    is classes( Oracle::refused( $source, $judgement ) ), ['brace yields code that perl refuses'],
      'the mutant with one brace too many is refused';
    is classes( Oracle::unresolved( $source, $judgement ) ), [], 'and a refused mutant calls nothing';
    $checked += $judgement->{verdicts}->@*;
};

subtest 'the call oracle rejects a mutator that swaps to an unimported name' => sub {
    my $swap = mutator(
        'swap',
        sub ($site) {
            return if $site->kind ne 'word' || $site->text ne 'max';
            return { replacement => 'min', description => 'replaced max with min' };
        }
    );
    my $mutants   = Oracle::generated( $source, [$swap] )->{mutants};
    my $judgement = Oracle::judgement( $source, $mutants, wants => ['calls'] );
    is [ map { $_->original } $mutants->@* ], ['max'],        'the import list holds no site, and the call holds one';
    is classes( Oracle::refused( $source, $judgement ) ), [], 'perl compiles the call of the unknown name';
    is classes( Oracle::unresolved( $source, $judgement ) ), ['swap introduces an unresolved call'],
      'and the walker finds no subroutine behind it';
    is $judgement->{verdicts}[0]{introduced}, ['Sample::min'], 'the verdict names the call';
    $checked += $judgement->{verdicts}->@*;
};

subtest 'the compile oracle rejects a file that perl refuses as it stands' => sub {
    my $broken    = Oracle::text_source( 'lib/Broken.pm', "use strict;\nsub f { return \$missing + 1 }\n1;\n" );
    my $judgement = Oracle::judgement( $broken, Oracle::generated($broken)->{mutants}, wants => ['calls'] );
    is $judgement->{problem},  'perl refuses the original', 'the file has no verdict';
    is $judgement->{verdicts}, [],                          'and neither has a mutant';
};

subtest 'the causes reject a here-document without its introducer and a variable without its declaration' => sub {
    my $text = <<'CODE';
use strict;
sub banner {
    return <<'EOT';
hello (
EOT
}
sub size {
    if ( my $n = shift ) { return $n }
    return 0;
}
1;
CODE
    my $unit    = Oracle::text_source( 'lib/Banner.pm', $text );
    my $removal = mutator(
        'blank',
        sub ($site) {
            return { replacement => q{}, description => 'removed the value' }   if $site->kind eq 'return';
            return { replacement => '1', description => 'fixed the condition' } if $site->kind eq 'condition';
            return;
        }
    );
    my $mutants   = Oracle::generated( $unit, [$removal] )->{mutants};
    my $judgement = Oracle::judgement( $unit, $mutants, wants => ['calls'] );
    is classes( Oracle::refused( $unit, $judgement ) ),
      [ 'blank removes a here-document introducer', 'blank leaves a variable without its declaration' ],
      'each refused mutant names its cause, and the sound ones name nothing';
    is scalar( $mutants->@* ),                        4,  'the unit holds three return values and one condition';
    is classes( Oracle::apart( $unit, $judgement ) ), [], 'and no mutant of the unit counts apart';
    $checked += $mutants->@*;
};

subtest 'the oracles reject no mutant that behaves as one: code of the compilation, and a branch that perl left out' =>
  sub {
    my $text = <<'CODE';
use strict;
use constant DEBUG => 0;
BEGIN { defined &TRACE or eval 'sub TRACE () { 0 }' }
BEGIN { die "no trace\n" if TRACE == 1 }
sub level { return TRACE ? 1 : 2 }
sub tool { if (DEBUG) { return missing_tool() } return 3 }
1;
CODE
    my $unit    = Oracle::text_source( 'lib/Phase.pm', $text );
    my $changes = mutator(
        'change',
        sub ($site) {
            return { replacement => q{},   description => 'removed the statement' }  if $site->kind eq 'statement';
            return { replacement => '1',   description => 'fixed the condition' }    if $site->kind eq 'condition';
            return { replacement => q{!=}, description => 'negated the comparison' } if $site->text eq q{==};
            return;
        }
    );
    my $mutants   = Oracle::generated( $unit, [$changes] )->{mutants};
    my $judgement = Oracle::judgement( $unit, $mutants, wants => ['calls'] );
    is [ map { $_->original } $mutants->@* ],
      [ q{defined &TRACE or eval 'sub TRACE () { 0 }'}, qq{die "no trace\\n" if TRACE == 1}, q{==}, 'DEBUG' ],
      'two statements of a block, a comparison of a block, and a constant condition';
    is classes( Oracle::refused( $unit, $judgement ) ),    [], 'no mutant counts as text that perl cannot parse';
    is classes( Oracle::unresolved( $unit, $judgement ) ), [], 'and none counts as a call that the mutant introduced';
    is classes( Oracle::apart( $unit, $judgement ) ),
      [
        'change changes code that the compilation runs',
        'change dies while a block of the compilation runs',
        'change reaches a call that the original leaves out',
      ],
      'each one counts apart, under its reason';
    $checked += $mutants->@*;
  };

subtest 'the load oracle rejects a mutant that leaves the file without a true value' => sub {
    my $code    = "package Loads;\nmy \$five = 5;\nmy \$limit = 10 / \$five;\nsub f { return 1 }\n1;\n";
    my $unit    = Oracle::text_source( 'lib/Loads.pm', $code );
    my $changes = mutator(
        'change',
        sub ($site) {
            return { replacement => '0', description => 'changed the number' } if $site->text =~ /\A[15]\z/;
            return;
        }
    );
    my $mutants   = Oracle::generated( $unit, [$changes] )->{mutants};
    my $judgement = Oracle::judgement( $unit, $mutants, wants => [ 'calls', 'load' ] );
    is [ map { $_->from->[0] } $mutants->@* ], [ 2, 4, 5 ],
      'a divisor, a return value, and the final value of the file';
    is [ map { $_->{loaded} } $judgement->{verdicts}->@* ], [ 0, 1, 0 ], 'two of the three mutants fail to load';
    is classes( Oracle::unloaded( $unit, $judgement ) ), ['change leaves the file without a true value'],
      'the final value is a finding';
    is classes( Oracle::apart( $unit, $judgement ) ), ['change dies while the file loads'],
      'and the division by zero is a mutant that behaves as one';
    is classes( Oracle::refused( $unit, $judgement ) ), [], 'perl compiles all three';
    $checked += $mutants->@*;

    my $false = Oracle::text_source( 'lib/False.pm', "package False;\nsub f { return 1 }\n0;\n" );
    is Oracle::judgement( $false, Oracle::generated($false)->{mutants}, wants => ['load'] )->{problem},
      'the original fails to load', 'a file that fails to load as it stands has no verdict of this oracle';
};

subtest 'the cross-check rejects a verdict of the server that perl -c does not give' => sub {
    my $changes = mutator(
        'change',
        sub ($site) {
            return { replacement => '}',   description => 'replaced + with }' }     if $site->text eq q{+};
            return { replacement => 'min', description => 'replaced max with min' } if $site->text eq 'max';
            return { replacement => q{/},  description => 'replaced * with /' }     if $site->text eq q{*};
            return;
        }
    );
    my $mutants   = Oracle::generated( $source, [$changes] )->{mutants};
    my $judgement = Oracle::judgement( $source, $mutants, wants => ['calls'] );
    is [ map { $_->{compiled} . q{ } . scalar $_->{introduced}->@* } $judgement->{verdicts}->@* ],
      [ '1 1', '0 0', '1 0' ], 'a mutant with a new call, a refused mutant, and a sound one';
    is Oracle::cross_checked( $source, $judgement ), { compared => 3, differences => [] },
      'perl -c gives the verdict of the server for each of the three';

    $judgement->{verdicts}[2]{compiled} = 0;
    $judgement->{verdicts}[0]{calls}    = [];
    is Oracle::cross_checked( $source, $judgement ),
      {
        compared    => 3,
        differences => [
            'lib/Sample.pm line 8: max -> min: the server names the calls [] and perl -c names [Sample::min]',
            'lib/Sample.pm line 13: * -> /: the server refuses the mutant and perl -c compiles it',
        ],
      },
      'a verdict that perl -c does not give is named with both answers';
    is Oracle::cross_checked( $source, $judgement, accepted => 0 )->{compared}, 3,
      'a refused mutant and a mutant with a call are compared in every case';
    $checked += 3;
};

subtest 'the literal oracle rejects a number that changes its base' => sub {
    my $unit    = Oracle::text_source( 'lib/Modes.pm', "chmod 0644, \$file;\nmy \$n = 41;\nmy \$z = 0;\n1;\n" );
    my @numbers = grep { $_->mutator eq 'number-literal' } Oracle::generated($unit)->{mutants}->@*;
    is [ map { $_->original . q{ } . $_->replacement } @numbers ], [ '0644 645', '41 42', '0 1', '1 0' ],
      'the tool adds one to the digits of every whole number';
    is classes( Oracle::rebased( $unit, \@numbers ) ), ['number-literal reads an octal literal as a decimal number'],
      'the octal literal that turns decimal is refused, and a decimal number or a zero is accepted';
    my @records = Oracle::text_records( $unit, { sites => [], mutants => \@numbers } );
    is [ map { $_->[2] } grep { $_->[0] eq 'finding' && $_->[1] eq 'literal' } @records ],
      ['number-literal reads an octal literal as a decimal number'], 'the records of a file hold the finding';
    $checked += @numbers;
};

subtest 'the code oracle rejects a mutant that compiles to the code of the original' => sub {
    my $unit = Oracle::text_source( 'lib/Folds.pm',
        "use strict;\nsub size { return 10 > 5 ? 'big' : 'small' }\nsub more { return \$_[0] > 5 }\n1;\n" );
    my @comparisons = grep { $_->mutator eq 'comparison' } Oracle::generated($unit)->{mutants}->@*;
    my $judgement   = Oracle::judgement( $unit, \@comparisons, wants => [ 'calls', 'deparse' ] );
    is [ map { $_->{mutant}->replacement . q{ } . $_->{same_code} } $judgement->{verdicts}->@* ],
      [ '>= 1', '<= 0', '>= 0', '<= 0' ],
      'perl folds the first comparison, and one of its mutants folds to the same value';
    is classes( Oracle::equivalent($judgement) ), ['comparison compiles to the code of the original'],
      'that mutant is a finding';
    my %count;
    $count{ $_->[2] } += $_->[3] for grep { $_->[0] eq 'count' } Oracle::judged_records( $unit, $judgement, 'deparse' );
    is \%count, { judged => 4, compared => 4, equivalent => 1 }, 'and the records count what perl compared';
    $checked += @comparisons;

    # B::Deparse dies on the code of some mutants, and such a mutant has no code to compare.
    my $verdict = $judgement->{verdicts}[1];
    $verdict->@{qw(undeparsed same_code)} = ( 'Unexpected statement modifier', 0 );
    is classes( Oracle::apart( $unit, $judgement ) ), ['comparison has code that B::Deparse cannot print'],
      'a mutant that B::Deparse cannot print counts apart';
    %count = ();
    $count{ $_->[2] } += $_->[3] for grep { $_->[0] eq 'count' } Oracle::judged_records( $unit, $judgement, 'deparse' );
    is \%count, { judged => 4, compared => 3, equivalent => 1, apart => 1 }, 'and it leaves the compared mutants';
};

subtest 'the tally rejects a table that hides a column' => sub {
    my $tally = Oracle::tally();
    Oracle::count( $tally, 'arithmetic', 'mutants', 4 );
    Oracle::count( $tally, 'arithmetic', 'refused', 1 );
    Oracle::count( $tally, 'call-swap',  'mutants', 2 );
    Oracle::count( $tally, 'call-swap',  'mutants', 1 );
    is [ Oracle::table( $tally, 'mutants', 'refused:mutants' ) ],
      [
        'mutator     mutants  refused',
        'arithmetic        4  1 (25.0%)',
        'call-swap         3  0 (0.0%)',
        'all               7  1 (14.3%)',
      ],
      'one row for each mutator, a rate beside each count, and the sums';
    is Oracle::total($tally), { mutants => 7, refused => 1 }, 'the sums of the columns';
    my %column = map { s/:.*//r => 1 } Oracle::columns();
    is [ grep { !$column{$_} }
          qw(mutants unchanged misplaced unpatchable repeated refused unresolved apart equivalent) ],
      [], 'the table of a run shows every oracle';
};

sub written ( $directory, $name, $text ) {
    open my $handle, '>:raw', "$directory/$name" or die "write $name: $!";
    print {$handle} $text or die "write $name: $!";
    close $handle         or die "close $name: $!";
    return "$directory/$name";
}

sub of_kind ( $kind, @records ) {
    return [ map { [ $_->@[ 1 .. $_->$#* ] ] } grep { $_->[0] eq $kind } @records ];
}

subtest 'the survey of a file rejects each defect once for a mutator and a class' => sub {
    my $directory = File::Temp->newdir;
    my $swap      = written( $directory, 'Swap.pm', <<'CODE' );
package Swap;
use strict;
use warnings;
use List::Util qw(max);

sub largest {
    return max(@_) + max( 1, 2 );
}

sub banner {
    return <<'EOT';
hello (
EOT
}

1;
CODE
    my @records = Oracle::survey($swap);
    is of_kind( 'problem', @records ), [], 'the file has no problem';
    is [ map { [ $_->@[ 0, 1 ] ] } of_kind( 'finding', @records )->@* ],
      [
        [ 'b',  'return-value removes a here-document introducer' ],
        [ 'b2', 'call-swap introduces an unresolved call' ],
      ],
      'the two defects of the file, the second one once for its two mutants';
    like of_kind( 'finding', @records )->[0][2], qr/Swap[.]pm line 11: <<'EOT' -> \| /, 'a finding shows an example';
    my %count;
    $count{ $_->[1] }{ $_->[0] } += $_->[2] for of_kind( 'count', @records )->@*;
    is $count{unresolved}, { 'call-swap'    => 2 }, 'the count holds every mutant of the class';
    is $count{refused},    { 'return-value' => 1 }, 'in the column of its oracle';
    is $count{judged}, $count{mutants}, 'perl judges every mutant unless the caller sets a limit';
    is of_kind( 'crossed', @records ), [ [4] ],
      'a cold perl confirms the refused mutant, both mutants with a call, and one sound mutant';
    is $count{patched}, $count{mutants}, 'and every mutant has its patch applied';
    $checked += $count{mutants}{$_} for keys $count{mutants}->%*;

    my %limited;
    $limited{ $_->[1] }{ $_->[0] } += $_->[2] for of_kind( 'count', Oracle::survey( $swap, judged => 1 ) )->@*;
    is $limited{judged}, { map { $_ => 1 } keys $count{mutants}->%* },
      'a limit keeps that many mutants of each mutator';

    my $returns = written( $directory, 'Returns.pm', "package Returns;\r\nsub one { return 1 }\r\n1;\r\n" );
    is [ Oracle::survey($returns) ], [ [ 'problem', 'analysis', 'the file has carriage returns' ] ],
      'a file that the tool leaves alone names the reason';
    my $refused  = written( $directory, 'Refused.pm', "use strict;\nsub f { return \$missing + 1 }\n1;\n" );
    my @unjudged = Oracle::survey($refused);
    is of_kind( 'problem', @unjudged ), [ [ 'judge', 'perl refuses the original' ] ], 'a file that perl refuses';
    ok scalar( grep { $_->[0] eq 'count' && $_->[2] eq 'mutants' } @unjudged ), 'still has its mutants counted';

    # The server holds the modules of its walker, and a unit may compile with them alone.
    my $leans = written( $directory, 'Leans.pm',
        "use strict;\nBEGIN { defined &Exporter::import or die qq{no exporter\\n} }\nsub f { return 1 + 2 }\n1;\n" );
    is of_kind( 'problem', Oracle::survey($leans) ), [ [ 'judge', 'plain perl -c refuses the original' ] ],
      'a file that compiles in the server alone has no verdict';
};

subtest 'the walk over files rejects a worker that ends badly' => sub {
    my $directory = File::Temp->newdir;
    my @paths     = map { written( $directory, "$_.txt", $_ x 3 ) } qw(a b c d e);
    my $records   = Oracle::each_file( \@paths, 3, sub ($path) { return [ 'size', -s $path ], [ 'name', "a\tb\n" ] } );
    is $records, [ map { ( [ $_, 'name', 'a b ' ], [ $_, 'size', 3 ] ) } @paths ],
      'every record comes back under its path, in a fixed order and on one line';
    my @parts = map { [ $paths[0], $_, 3 ] } 0 .. 2;
    is Oracle::each_file( \@parts, 2, sub ( $path, $part, $of ) { return [ 'part', "$part of $of" ] } ),
      [ map { [ $paths[0], 'part', "$_ of 3" ] } 0 .. 2 ], 'a task carries its own arguments after the path';
    like dies {
        Oracle::each_file( \@paths, 2, sub ($path) { die "no $path\n" if $path =~ /c[.]txt/; return } )
    }, qr/\Aa worker of the walk ended badly/, 'a death in a worker fails the walk';

    my $swap = written( $directory, 'Parts.pm',
        "use strict;\nsub f { my (\$n) = \@_; return \$n + 1 if \$n > 2; return \$n * 2 - 1 }\n1;\n" );
    my %whole;
    $whole{ $_->[2] } += $_->[3] for grep { $_->[0] eq 'count' } Oracle::survey($swap);
    my %split;
    for my $part ( 0 .. 2 ) {
        $split{ $_->[2] } += $_->[3] for grep { $_->[0] eq 'count' } Oracle::survey( $swap, part => [ $part, 3 ] );
    }
    is \%split, \%whole, 'the parts of a file hold each mutant once, and the first part holds what needs no judge';
    ok $whole{judged} > 9, "the file has enough mutants for three parts ($whole{judged})";
};

subtest 'the summary of a walk rejects a finding without its oracle and a problem without its file' => sub {
    my $summary = Oracle::summary(
        [
            [ 'lib/A.pm', 'sites',   9 ],
            [ 'lib/B.pm', 'sites',   4 ],
            [ 'lib/A.pm', 'crossed', 3 ],
            [ 'lib/B.pm', 'crossed', 2 ],
            [ 'lib/A.pm', 'count',   'arithmetic', 'mutants',                         3 ],
            [ 'lib/A.pm', 'count',   'call-swap',  'mutants',                         2 ],
            [ 'lib/A.pm', 'count',   'call-swap',  'unresolved',                      1 ],
            [ 'lib/A.pm', 'finding', 'b2', 'call-swap introduces an unresolved call', 'lib/A.pm line 3: max -> min' ],
            [ 'lib/B.pm', 'count',   'call-swap', 'mutants',                          1 ],
            [ 'lib/B.pm', 'count',   'call-swap', 'unresolved',                       1 ],
            [ 'lib/B.pm', 'finding', 'b2', 'call-swap introduces an unresolved call', 'lib/B.pm line 9: any -> all' ],
            [ 'lib/C.pm', 'problem', 'analysis', 'the file has carriage returns' ],
            [ 'lib/D.pm', 'problem', 'judge',    'the judge broke', 'no B' ],
        ]
    );
    is [ Oracle::table( $summary->{tally}, 'mutants', 'unresolved:mutants' ) ],
      [
        'mutator     mutants  unresolved',
        'arithmetic        3  0 (0.0%)',
        'call-swap         3  2 (66.7%)',
        'all               6  2 (33.3%)',
      ],
      'the counts of every file in one table';
    is $summary->{sites},               13, 'the sites of every file';
    is $summary->{files},               2,  'and the files that have them';
    is $summary->{crossed},             5,  'the verdicts that a cold perl confirmed';
    is Oracle::found( $summary, 'b2' ), ['call-swap introduces an unresolved call'], 'the findings of one oracle';
    is Oracle::found( $summary, 'b' ),  [],                                          'and none of another one';
    is $summary->{problems},
      { 'analysis: the file has carriage returns' => ['lib/C.pm'], 'judge: the judge broke' => ['lib/D.pm'] },
      'the files of each problem';
    is [ Oracle::lines($summary) ],
      [
        'b2: call-swap introduces an unresolved call, in 2 files, as in lib/A.pm line 3: max -> min',
        'analysis: the file has carriage returns, in 1 file, as in lib/C.pm',
        'judge: the judge broke, in 1 file, as in lib/D.pm (no B)',
      ],
      'one line for each finding and each problem, with the number of its files and one example';
};

Gate::checked( 'mutants and changes', $checked, at_least => 400 );

done_testing;
