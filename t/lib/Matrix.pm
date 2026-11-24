package Matrix;
use v5.36;
use Digest::SHA ();
use Encode      ();
use File::Temp  ();
use POSIX       ();
use Oracle;
use Snippets;

# Oracle c2: some input tells a mutant of an expression from the original.
# The expression is the value of a subroutine, and each row of the matrix gives its variables their values.
# A mutant that gives what the original gives in every row, in list and in scalar context, has no such input.

# A list of millions of items in each call of each row costs a child of one expression up to a minute.
my $SECONDS = 120;

# The values of the variables: an equal pair, zero, a negative number, an empty string, and a string that holds no number.
# The values stay small, as an operand of `x` or of `..` may take them.
my @VALUES = ( -2, 0, 1, 3, q{}, 'a' );

# The shapes of the reference, built anew for each call, as an operator may assign through the reference.
# The key holds a true, a negative, a zero, and an empty value, and the list holds from one item to three.
# Perl shifts the last index -1 of an empty list as the unsigned number 2**64 - 1, and a list that long takes all memory.
my @SHAPES = (
    sub { { k =>  5,  list => [ 1, 2 ] } },
    sub { { k => -1,  list => [ 0, 'a', 3 ] } },
    sub { { k =>  0,  list => [4] } },
    sub { { k => q{}, list => [ 3, 'a' ] } },
);

# Every pair of the values for the two scalar variables, each pair with every shape of the reference.
sub rows (@values) {
    @values = @VALUES if !@values;
    my @rows;
    for my $x (@values) {
        for my $y (@values) {
            push @rows, map { [ $x, $y, $_ ] } 0 .. $#SHAPES;
        }
    }
    return @rows;
}

# The text of a snippet in a package of its own, with a subroutine that sets the variables of a row.
sub _variant ( $text, $index ) {
    my $count = () = $text =~ /^package [\w:]+;$/mg;
    die "a snippet holds one package\n" if $count != 1;
    my $placed = $text =~ s/^package [\w:]+;$/package Matrix::V$index;/mr;
    return $placed
      . "sub matrix_row { ( \$x, \$y, \$r ) = \@_; return }\nsub matrix_state { return ( \$x, \$y, \$r ) }\n1;\n";
}

my $ENDS = 32;

# A list shows its length and the items at both ends, as an operator may grow it to millions of items.
sub _shown ($value) {
    return 'undef'     if !defined $value;
    return "'$value'"  if !ref $value;
    return ref($value) if ref $value ne 'ARRAY' && ref $value ne 'HASH';
    if ( ref $value eq 'ARRAY' ) {
        my $last  = $value->$#*;
        my @shown = $last < 2 * $ENDS ? ( 0 .. $last ) : ( 0 .. $ENDS - 1, $last - $ENDS + 1 .. $last );
        return '[' . ( $last + 1 ) . q{:} . join( q{,}, map { _shown( $value->[$_] ) } @shown ) . ']';
    }
    return '{' . join( q{,}, map { "$_=" . _shown( $value->{$_} ) } sort keys $value->%* ) . '}';
}

# What one call gives: its value or the reason of its death without the place, and the variables after it.
sub _call ( $package, $row, $context ) {
    my ( $x, $y, $shape ) = $row->@*;
    $package->can('matrix_row')->( $x, $y, $SHAPES[$shape]->() );
    my $code = $package->can('c');
    my @got;
    my $done = eval {
        @got = $context eq 'list' ? $code->() : scalar $code->();
        1;
    };
    my $value = $done ? join q{,}, map { _shown($_) } @got : 'died: ' . $@ =~ s/ at \S+ line \d+[.]?\s*\z//r;
    my $state = join q{ }, map { _shown($_) } $package->can('matrix_state')->();

    # A repetition may make a string of millions of characters, so a digest stands for what one call gives.
    return Digest::SHA::sha1_hex( Encode::encode( 'UTF-8', "$context=$value $state" ) );
}

sub _observed ( $package, $rows ) {
    my @calls;
    for my $row ( $rows->@* ) {
        push @calls, map { _call( $package, $row, $_ ) } qw(list scalar);
    }
    return join "\n", @calls;
}

# What each text gives over the rows, or nothing for a text that perl refuses to load.
# One child loads every text, each in a package of its own, so the test process never runs a snippet.
sub observed ( $texts, $rows ) {
    my $directory = File::Temp->newdir;
    my @paths;
    for my $index ( 0 .. $texts->$#* ) {
        my $path = "$directory/$index.pm";
        open my $handle, '>:encoding(UTF-8)', $path or die "write $path: $!\n";
        print {$handle} _variant( $texts->[$index], $index ) or die "write $path: $!\n";
        close $handle                                        or die "close $path: $!\n";
        push @paths, $path;
    }
    my $pid = open my $from, q{-|};
    die "fork: $!\n" if !defined $pid;
    if ( !$pid ) {
        alarm $SECONDS;
        for my $index ( 0 .. $#paths ) {
            my $loaded = eval { require $paths[$index]; 1 };
            my $seen   = $loaded ? _observed( "Matrix::V$index", $rows ) : undef;
            print defined $seen ? unpack( 'H*', $seen ) : q{-}, "\n" or POSIX::_exit(1);
        }

        # The child leaves without the END blocks of the test, so it writes out its buffer itself.
        POSIX::_exit( close STDOUT ? 0 : 1 );
    }
    my @lines = readline $from;
    die "the child that runs the snippets ended badly\n" if !close $from || @lines != @paths;
    chomp @lines;
    return [ map { $_ eq q{-} ? undef : pack 'H*', $_ } @lines ];
}

# The mutants of a source that perl loads, and among them the ones that give what the original gives in every row.
sub inseparable ( $source, $mutants, $rows ) {
    my @texts = ( $source->text, map { $source->replace_span( $_->start, $_->end, $_->replacement ) } $mutants->@* );
    my ( $original, @seen ) = observed( \@texts, $rows )->@*;
    return { loaded => 0, executed => [], equal => [] } if !defined $original;
    my @executed = grep { defined $seen[$_] } 0 .. $#seen;
    return {
        loaded   => 1,
        executed => [ $mutants->@[@executed] ],
        equal    => [ map { $mutants->[$_] } grep { $seen[$_] eq $original } @executed ],
    };
}

my $CLASS = 'has no input of the matrix that tells it from the original';

# The records of the mutants of an expression: what perl ran, what no row separates, and a finding for each mutator.
sub judged_records ( $source, $mutants, $rows, $label ) {
    my $result = eval { inseparable( $source, $mutants, $rows ) };
    return [ 'problem', 'matrix', $@ =~ s/\n\z//r, $label ] if !$result;
    return [ 'expression', 'refused' ] if !$result->{loaded};
    my %seen;
    my @first = grep { !$seen{ $_->mutator }++ } $result->{equal}->@*;
    return (
        [ 'expression', 'run' ],
        ( map { [ 'count', $_->mutator, 'executed' ] } $result->{executed}->@* ),
        ( map { [ 'count', $_->mutator, 'inseparable' ] } $result->{equal}->@* ),
        (
            map { [ 'finding', 'c2', $_->mutator . " $CLASS", "$label: " . $_->original . ' -> ' . $_->replacement ] }
              @first
        ),
    );
}

# The records of an expression as the value of a subroutine, for every mutant inside the expression.
sub expression_records ( $context, $expression, $rows ) {
    my $file   = Snippets::file( $context, $expression );
    my $source = Oracle::text_source( "$context->{name}: $expression->{text}", $file->{text} );
    my $made   = Oracle::generated($source);
    return [ 'problem', 'analysis', $made->{problem}, $made->{detail} ] if defined $made->{problem};
    my ( $from, $to ) = $file->{spans}[0]->@*;
    my @inside = grep { $_->start >= $from && $_->end <= $to } $made->{mutants}->@*;
    return judged_records( $source, \@inside, $rows, $expression->{text} );
}

# The expressions of a list of tuples: the operator and the operand on each side.
sub expressions (@tuples) {
    my @operators = Snippets::operators();
    my @operands  = Snippets::operands();
    return map { Snippets::expression( $operators[ $_->[0] ], @operands[ $_->[1], $_->[2] ] ) } @tuples;
}

# Every expression as the value of a subroutine through the matrix, as the summary of a walk.
# `expressions` beside the summary counts the expressions that perl runs and the ones that it refuses.
sub surveyed ( $expressions, $workers, $rows ) {
    my ($return) = grep { $_->{name} eq 'return' } Snippets::contexts();
    my $shares   = 4 * $workers;
    my $records  = Oracle::each_file(
        [ map { [ "share $_", $_, $shares ] } 0 .. $shares - 1 ],
        $workers,
        sub ( $name, $share, $of ) {
            return map { expression_records( $return, $expressions->[$_], $rows ) }
              grep { $_ % $of == $share } 0 .. $expressions->$#*;
        }
    );
    my %count;
    $count{ $_->[2] }++ for grep { $_->[1] eq 'expression' } $records->@*;
    my $summary = Oracle::summary( [ grep { $_->[1] ne 'expression' } $records->@* ] );
    $summary->{expressions} = \%count;
    return $summary;
}

1;
