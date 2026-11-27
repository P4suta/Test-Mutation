package Layouts;
use v5.36;
use Oracle;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Suppression;

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
    { name => 'named sub',       own => 1, text => '## no mutate sub (arithmetic): the sum is a constant' },
    { name => 'unknown name',    own => 0, text => '## no mutate (arithmetc)' },
    { name => 'idle name',       own => 0, text => '## no mutate (regex-anchor)' },
    { name => 'single hash',     own => 0, text => '# no mutate' },
    { name => 'other noun',      own => 0, text => '## no mutation' },
    { name => 'no space',        own => 0, text => '##no mutate' },
    { name => 'end behind code', own => 0, text => '## use mutate' },
    { name => 'sub behind code', own => 0, text => '## no mutate sub' },
    { name => 'named end',       own => 1, text => '## use mutate (arithmetic)' },
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

# The errors of the tool in the words of the interpreter, by the identifier of the message of each refusal.
my %ERROR_OF = (
    'suppression-malformed'       => 'a candidate that is not canonical',
    'suppression-mutator-unknown' => 'an unknown mutator name',
    'suppression-end-unopened'    => 'a use mutate without an open block',
    'suppression-block-nested'    => 'a second no mutate inside an open block',
    'suppression-block-unclosed'  => 'a block without its use mutate',
    'suppression-sub-missing'     => 'a no mutate sub without a subroutine after it',
    'suppression-unused'          => 'a directive that suppresses no mutant',
);

# A layout as the tool reads it: its mutants with the line, the mutator, and the mark of suppression, and every error.
# The tool judges a comment by the mutants of every mutator, as a run does whatever mutators it chooses.
sub made ($layout) {
    my $made = Oracle::generated( Oracle::text_source( 'lib/Layout.pm', $layout->{text} ) );
    die "the tool makes no mutant of a layout: $made->{problem}\n" if defined $made->{problem};
    my $refusals = Test::Mutation::Suppression::refusals(
        path        => 'lib/Layout.pm',
        suppression => $made->{suppressions},
        mutants     => $made->{mutants}
    );
    return {
        mutants => [
            map { { line => $_->from->[0], mutator => $_->mutator, suppressed => $_->suppressed ? 1 : 0 } }
              $made->{mutants}->@*
        ],
        errors => [
            map { { error => exists $ERROR_OF{ $_->{id} } ? $ERROR_OF{ $_->{id} } : $_->{id}, line => $_->{line} } }
              $refusals->@*
        ],
    };
}

sub mutants ($layout) {
    return made($layout)->{mutants};
}

my %KNOWN     = map { $_->name => 1 } Test::Mutation::Mutator::Catalog::mutators()->@*;
my $CANDIDATE = qr/\A\s*[#]+\s*(?:no|use)\s*mutat/i;
my $CANONICAL = qr/\A[#][#][ ](no|use)[ ]mutate([ ]sub)?(?:[ ][(]([a-z-]+(?:,[ ][a-z-]+)*)[)])?(?::[ ](.+))?\z/;

# How the grammar reads one candidate: the end of a block, the kind of range that it starts, or the error that it is.
# An end stands alone on a line of its own, and a comment that names a subroutine stands on a line of its own.
# A comment in a place or a form outside the grammar is no candidate for the check of its names.
sub _reading ( $comment, $open ) {
    my ( $verb, $sub, $list, $reason ) = $comment->{text} =~ $CANONICAL;
    my $own = $comment->{own};
    return 'a candidate that is not canonical' if !defined $verb;
    return 'a candidate that is not canonical'
      if $verb eq 'use' && ( !$own || $sub || defined $list || defined $reason );
    return 'a candidate that is not canonical' if $sub && !$own;
    return 'an unknown mutator name'           if defined $list && grep { !$KNOWN{$_} } split /,[ ]/, $list;
    return $open ? 'end' : 'a use mutate without an open block' if $verb eq 'use';
    return 'line'                                               if !$own;
    return $comment->{before_sub} ? 'sub' : 'a no mutate sub without a subroutine after it' if $sub;
    return $open ? 'a second no mutate inside an open block' : 'block';
}

# The last line of a range, counted from its comment: the same line, the subroutine on the next line, or no line yet.
my %LAST = ( line => 0, sub => 1, block => undef );

# The reference interpreter: the ranges that the comments of a layout suppress, and every error of the layout with its line.
# A comment with an error suppresses nothing, and the interpreter reads on to collect every error.
# A block that the layout leaves open is an error on the line of its comment.
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
            push @errors, { error => $reading, line => $line };
        }
    }
    push @errors, { error => 'a block without its use mutate', line => $open->{first} } if $open;
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
# A range starts on the line of its comment, so an idle comment is an error on that line.
sub expected ( $layout, $mutants ) {
    my ( $ranges, $errors ) = _interpreted( $layout->{comments} );
    for my $range ( $ranges->@* ) {
        push $errors->@*, { error => 'a directive that suppresses no mutant', line => $range->{first} }
          if !grep { _covers( $range, $_ ) } $mutants->@*;
    }
    return { errors => $errors, suppressed => [ map { _covered( $ranges, $_ ) } $mutants->@* ] };
}

# Why the parser suppresses other mutants than the interpreter, named after the first cause that the layout shows.
sub _misreading ( $layout, $errors ) {
    my %error = map { $_->{error} => 1 } $errors->@*;
    return 'reads no mutate sub as the start of a block'
      if grep { $_->{text} =~ /mutate[ ]sub/ } $layout->{comments}->@*;
    return 'starts a second block inside an open block and never ends the first one'
      if $error{'a second no mutate inside an open block'};
    return 'obeys a candidate that is not canonical' if $error{'a candidate that is not canonical'};
    return 'suppresses other mutants than the grammar';
}

# The differences between the parser of the tool and the interpreter for one layout, each as the text of a finding.
sub differences ($layout) {
    return differences_of( $layout, made($layout) );
}

# The mutants of a layout with the marks of a reader that a test plays, and the errors that the reader reports.
# The code tells for each mutant whether that reader suppresses it.
sub marked ( $layout, $suppresses, @errors ) {
    my @marked;
    for my $mutant ( mutants($layout)->@* ) {
        push @marked, { $mutant->%*, suppressed => $suppresses->($mutant) ? 1 : 0 };
    }
    return { mutants => \@marked, errors => \@errors };
}

# The differences for a reading that the caller holds: the one of the tool, or one that a test marked by hand.
# Each error counts with its line, so an error that the parser reports on another line is missing on one line and extra on the other.
sub differences_of ( $layout, $made ) {
    my $mutants  = $made->{mutants};
    my $expected = expected( $layout, $mutants );
    my %balance;
    $balance{"$_->{line}\t$_->{error}"}++ for $expected->{errors}->@*;
    $balance{"$_->{line}\t$_->{error}"}-- for $made->{errors}->@*;
    my %found;
    for my $key ( grep { $balance{$_} } keys %balance ) {
        my ( undef, $error ) = split /\t/, $key;
        $found{
            $balance{$key} > 0
            ? "the parser accepts $error"
            : "the parser reports $error where the grammar has none"
        } = 1;
    }
    my @differ = grep { $mutants->[$_]{suppressed} != $expected->{suppressed}[$_] } 0 .. $mutants->$#*;
    $found{ 'the parser ' . _misreading( $layout, $expected->{errors} ) } = 1 if @differ;
    return [ sort keys %found ];
}

1;
