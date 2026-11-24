package Layouts;
use v5.36;
use Oracle;
use Test::Mutation::Mutator::Catalog;

# The layouts of suppression comments, and a reference interpreter of their grammar.
# The interpreter follows the grammar of the plan and reads nothing of the parser of the tool.
#
#   no-line   := code '## no mutate' [' (' name {', ' name} ')'] [': ' reason]
#   no-block  := '## no mutate' ...       on a line of its own, closed by '## use mutate'
#   no-sub    := '## no mutate sub' ...   on a line of its own, before a named subroutine
#   candidate := a comment that matches /\A\s*#+\s*(?:no|use)\s*mutat/i

# The forms of a comment: the canonical ones, a name, a misspelt name, the near misses, and both places of a comment.
my @FORMS = (
    { name => 'block',           own => 1, text => '## no mutate' },
    { name => 'end',             own => 1, text => '## use mutate' },
    { name => 'line',            own => 0, text => '## no mutate' },
    { name => 'named line',      own => 0, text => '## no mutate (arithmetic)' },
    { name => 'named block',     own => 1, text => '## no mutate (arithmetic, return-value)' },
    { name => 'reason',          own => 0, text => '## no mutate (arithmetic): the sum is a constant' },
    { name => 'sub',             own => 1, text => '## no mutate sub' },
    { name => 'unknown name',    own => 0, text => '## no mutate (arithmetc)' },
    { name => 'idle name',       own => 0, text => '## no mutate (regex-anchor)' },
    { name => 'single hash',     own => 0, text => '# no mutate' },
    { name => 'other noun',      own => 0, text => '## no mutation' },
    { name => 'no space',        own => 0, text => '##no mutate' },
    { name => 'end behind code', own => 0, text => '## use mutate' },
);

sub forms () {
    return @FORMS;
}

# Every sequence of at most a limit of items, each item a number below the count, the shortest sequence first.
sub sequences ( $count, $limit ) {
    my @all  = ( [] );
    my @last = ( [] );
    for my $length ( 1 .. $limit ) {
        my @longer;
        for my $head (@last) {
            push @longer, map { [ $head->@*, $_ ] } 0 .. $count - 1;
        }
        @last = @longer;
        push @all, @last;
    }
    return @all;
}

# A file with one slot of code for each comment: a subroutine in the odd slots and a statement in the even ones.
# A comment stands on the line before its slot or behind the code of its slot.
sub rendered (@forms) {
    my @lines = ('use strict; my ( $m, $n ) = ( 1, 2 );');
    my @comments;
    for my $slot ( 1 .. @forms ) {
        my $form   = $forms[ $slot - 1 ];
        my $is_sub = $slot % 2;

        # Each line holds mutants of more than one mutator, so a comment that names one mutator differs from one that names none.
        my $code = $is_sub ? "sub s$slot { return \$_[0] + \$_[1] }" : "my \$v$slot = \$m + \$n * 2;";
        push @lines, $form->{text} if $form->{own};
        push @comments,
          {
            line       => @lines + ( $form->{own} ? 0 : 1 ),
            own        => $form->{own},
            text       => $form->{text},
            before_sub => $form->{own} && $is_sub ? 1 : 0
          };
        push @lines, $form->{own} ? $code : "$code    $form->{text}";
    }
    push @lines, 'my $last = $m - $n * 2;', '1;';
    return { text => join( q{}, map { "$_\n" } @lines ), comments => \@comments };
}

# The mutants of a layout as the tool makes them: the line, the mutator, and whether the tool suppresses the mutant.
sub mutants ($layout) {
    my $made = Oracle::generated( Oracle::text_source( 'lib/Layout.pm', $layout->{text} ) );
    die "the tool makes no mutant of a layout: $made->{problem}\n" if defined $made->{problem};
    return [ map { { line => $_->from->[0], mutator => $_->mutator, suppressed => $_->suppressed ? 1 : 0 } }
          $made->{mutants}->@* ];
}

my %KNOWN     = map { $_->name => 1 } Test::Mutation::Mutator::Catalog::mutators()->@*;
my $CANDIDATE = qr/\A\s*[#]+\s*(?:no|use)\s*mutat/i;
my $CANONICAL = qr/\A[#][#][ ](no|use)[ ]mutate([ ]sub)?(?:[ ][(]([a-z-]+(?:,[ ][a-z-]+)*)[)])?(?::[ ].+)?\z/;

# How the grammar reads one candidate: the end of a block, the kind of range that it starts, or the error that it is.
sub _reading ( $comment, $open ) {
    my ( $verb, $sub, $list ) = $comment->{text} =~ $CANONICAL;
    return 'a candidate that is not canonical' if !defined $verb;
    return 'an unknown mutator name' if defined $list && grep { !$KNOWN{$_} } split /,[ ]/, $list;
    my $own = $comment->{own};
    if ( $verb eq 'use' ) {
        return 'a candidate that is not canonical' if !$own || $sub || defined $list;
        return $open ? 'end' : 'a use mutate without an open block';
    }
    return $sub                   ? 'a candidate that is not canonical' : 'line' if !$own;
    return $comment->{before_sub} ? 'sub' : 'a no mutate sub without a subroutine after it' if $sub;
    return $open                  ? 'a second no mutate inside an open block' : 'block';
}

# The last line of a range, counted from its comment: the same line, the subroutine on the next line, or no line yet.
my %LAST = ( line => 0, sub => 1, block => undef );

# The reference interpreter: the ranges that the comments of a layout suppress, and every error of the layout.
# A comment with an error suppresses nothing, and the interpreter reads on to collect every error.
sub _interpreted ($comments) {
    my ( @ranges, @errors, $open );
    for my $comment ( grep { $_->{text} =~ $CANDIDATE } $comments->@* ) {
        my $reading = _reading( $comment, $open );
        my $line    = $comment->{line};
        if ( $reading eq 'end' ) {
            $open->{last} = $line;
            $open = undef;
        }
        elsif ( exists $LAST{$reading} ) {
            my ($list) = $comment->{text} =~ /[(]([^)]*)[)]/;
            my $after = $LAST{$reading};
            push @ranges,
              {
                first => $line,
                last  => defined $after ? $line + $after          : undef,
                names => defined $list  ? [ split /,[ ]/, $list ] : undef
              };
            $open = $ranges[-1] if $reading eq 'block';
        }
        else {
            push @errors, $reading;
        }
    }
    push @errors, 'a block without its use mutate' if $open;
    return ( \@ranges, \@errors );
}

sub _covers ( $range, $mutant ) {
    return 0 if $mutant->{line} < $range->{first} || ( defined $range->{last} && $mutant->{line} > $range->{last} );
    return !$range->{names}                       || ( grep { $_ eq $mutant->{mutator} } $range->{names}->@* ) ? 1 : 0;
}

sub _covered ( $ranges, $mutant ) {
    return ( grep { _covers( $_, $mutant ) } $ranges->@* ) ? 1 : 0;
}

# What the grammar asks of a layout: the errors that refuse it, and for each mutant whether a comment suppresses it.
sub expected ( $layout, $mutants ) {
    my ( $ranges, $errors ) = _interpreted( $layout->{comments} );
    for my $range ( $ranges->@* ) {
        push $errors->@*, 'a directive that suppresses no mutant' if !grep { _covers( $range, $_ ) } $mutants->@*;
    }
    return { errors => $errors, suppressed => [ map { _covered( $ranges, $_ ) } $mutants->@* ] };
}

# Why the parser suppresses other mutants than the interpreter, named after the first cause that the layout shows.
sub _misreading ( $layout, $errors ) {
    my %error = map { $_ => 1 } $errors->@*;
    return 'reads no mutate sub as the start of a block'
      if grep { $_->{text} =~ /mutate[ ]sub/ } $layout->{comments}->@*;
    return 'starts a second block inside an open block and never ends the first one'
      if $error{'a second no mutate inside an open block'};
    return 'obeys a candidate that is not canonical' if $error{'a candidate that is not canonical'};
    return 'suppresses other mutants than the grammar';
}

# The differences between the parser of the tool and the interpreter for one layout, each as the text of a finding.
# The parser refuses no layout, so every error of the grammar is a layout that the parser accepts.
sub differences ($layout) {
    return differences_of( $layout, mutants($layout) );
}

# The mutants of a layout with the marks of a reader that a test plays.
# The code tells for each mutant whether that reader suppresses it.
sub marked ( $layout, $suppresses ) {
    my @marked;
    for my $mutant ( mutants($layout)->@* ) {
        push @marked, { $mutant->%*, suppressed => $suppresses->($mutant) ? 1 : 0 };
    }
    return \@marked;
}

# The differences for mutants that the caller holds: the ones of the tool, or ones that a test marked by hand.
sub differences_of ( $layout, $mutants ) {
    my $expected = expected( $layout, $mutants );
    my %found    = map  { ( "the parser accepts $_" => 1 ) } $expected->{errors}->@*;
    my @differ   = grep { $mutants->[$_]{suppressed} != $expected->{suppressed}[$_] } 0 .. $mutants->$#*;
    $found{ 'the parser ' . _misreading( $layout, $expected->{errors} ) } = 1 if @differ;
    return [ sort keys %found ];
}

1;
