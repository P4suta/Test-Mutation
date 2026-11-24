package Discovery::Known;
use v5.36;
use Digest::SHA ();
use File::Temp  ();

# A known-answer project holds one cell on each line: a pure function of one expression.
# A plain interpreter loads the original and each mutated text and calls the cell with the inputs of every test.
# The truth of a mutant therefore owes nothing to the delivery, the pool, the TAP reader, or the verdict code of the tool.

my $HEADER     = "package %s;\nuse strict;\nuse warnings;\n";
my $FIRST_LINE = 4;
my $LIMIT      = 1;
my $TOGETHER   = 12;

my @SHAPES = (
    { body => 'return $x %s $y',                 operators => [qw(+ - *)],           domain => [ 0 .. 4 ] },
    { body => 'return $x %s $y ? 1 : 0',         operators => [qw(< <= > >= == !=)], domain => [ 0 .. 4 ] },
    { body => q{return $x %s $y ? 'yes' : 'no'}, operators => [qw(&& ||)],           domain => [ 0,   1 ] },
    { body => 'return $x %s $y ? 1 : 0',         operators => [qw(eq ne lt gt)],     domain => [ 'a', 'b', q{} ] },
);
my $GUARD = q[BEGIN { die "the guard fails\n" if 2 * 3 != 6 }];
my $LOOP  = q[sub %s { my ($x) = @_; my $i = 0; $i += 1 while $i < $x; return $i }];
my $CELL  = q[sub %s { my ( $x, $y ) = @_; %s }];

my $EVALUATOR = <<'PERL';
use strict;
use warnings;
use Time::HiRes qw(alarm);
my ( $file, $package, $limit, $list ) = @ARGV;
open STDERR, '>', '/dev/null' or die "stderr: $!";
open my $handle, '<', $list or die "read $list: $!";
my @calls = map { chomp; [ split /\t/, $_, -1 ] } <$handle>;
close $handle or die "close $list: $!";
if ( !eval { require $file; 1 } ) {
    print "uncompiled\n";
    exit 0;
}
for my $call (@calls) {
    my ( $cell, @arguments ) = @{$call};
    my $outcome = eval {
        local $SIG{ALRM} = sub { die "looped\n" };
        alarm $limit;
        my $value = $package->can($cell)->(@arguments);
        alarm 0;
        defined $value ? "value $value" : 'undefined';
    };
    alarm 0;
    $outcome = $@ eq "looped\n" ? 'looped' : 'died' if !defined $outcome;
    print "$outcome\n";
}
PERL

# A choice depends on the seed and on its own label alone, so one more cell leaves every other choice as it was.
sub _pick ( $seed, $label, $count ) {
    return hex( substr Digest::SHA::sha256_hex("$seed $label"), 0, 8 ) % $count;
}

sub quoted ($text) {
    return q{'} . $text =~ s/([\\'])/\\$1/gr . q{'};
}

# Distinct pairs of the domain, in an order that the seed chooses.
sub _rows ( $seed, $number, $domain, $count ) {
    my ( @pairs, @rows );
    for my $x ( $domain->@* ) {
        push @pairs, map { [ $x, $_ ] } $domain->@*;
    }
    for my $row ( 1 .. $count ) {
        last if !@pairs;
        push @rows, splice @pairs, _pick( $seed, "row $number $row", scalar @pairs ), 1;
    }
    return \@rows;
}

sub _seeded ( $spec, $tests ) {
    my @cells;
    for my $number ( 1 .. $spec->{cells} ) {
        my $shape    = $SHAPES[ _pick( $spec->{seed}, "shape $number", scalar @SHAPES ) ];
        my @operator = $shape->{operators}->@*;
        push @cells,
          {
            body =>
              sprintf( $shape->{body}, $operator[ _pick( $spec->{seed}, "operator $number", scalar @operator ) ] ),
            test => $number <= $spec->{cells} - $spec->{idle} ? $tests->[ ( $number - 1 ) % $tests->@* ] : undef,
            rows => _rows( $spec->{seed}, $number, $shape->{domain}, $spec->{rows} ),
          };
    }
    return @cells;
}

# `cells` is a number of cells that the seed shapes, or a list of cells with a body, the rows, and the test that calls them.
sub new ( $class, %arg ) {
    my %spec  = ( seed => 0, cells => 4, idle => 1, tests => 2, rows => 2, loop => 0, guard => 0, %arg );
    my @tests = map { "t/$_.t" } ( 'a' .. 'z' )[ 0 .. $spec{tests} - 1 ];
    my @cells = ref $spec{cells} ? $spec{cells}->@* : _seeded( \%spec, \@tests );
    my @lines = ( $spec{guard} ? { kind => 'guard', text => $GUARD, rows => [] } : () );
    for my $number ( 1 .. @cells ) {
        my $cell = $cells[ $number - 1 ];
        my $name = "cell_$number";
        push @lines,
          { kind => 'cell', name => $name, text => sprintf( $CELL, $name, $cell->{body} ), $cell->%{qw(test rows)} };
    }
    push @lines,
      {
        kind => 'cell',
        name => 'cell_loop',
        text => sprintf( $LOOP, 'cell_loop' ),
        test => $tests[-1],
        rows => [ [2] ]
      }
      if $spec{loop};

    my $directory = File::Temp->newdir( 'known-XXXXXX', TMPDIR => 1 );
    my $self = bless { directory => $directory, tests => \@tests, lines => \@lines, truth => {}, count => 0 }, $class;
    _spew( "$directory/evaluate.pl", $EVALUATOR );
    $self->_expect;
    return $self;
}

sub tests ($self) {
    return $self->{tests}->@*;
}

sub module ( $self, $package ) {
    return sprintf( $HEADER, $package ) . join( q{}, map { "$_->{text}\n" } $self->{lines}->@* ) . "1;\n";
}

# The rows that a test asserts: a cell, its inputs, and the value of the original.
sub rows ( $self, $test ) {
    my @rows;
    for my $line ( grep { defined $_->{test} && $_->{test} eq $test } $self->{lines}->@* ) {
        push @rows, map { [ $line->{name}, $_, $line->{expected}{"@{$_}"} ] } $line->{rows}->@*;
    }
    return \@rows;
}

sub _spew ( $path, $content ) {
    open my $handle, '>:raw', $path or die "write $path: $!";
    print {$handle} $content or die "write $path: $!";
    close $handle            or die "close $path: $!";
    return;
}

sub _cells ($self) {
    return grep { $_->{kind} eq 'cell' } $self->{lines}->@*;
}

sub _calls (@lines) {
    my @calls;
    for my $line (@lines) {
        push @calls, map { [ $line->{name}, $_->@* ] } $line->{rows}->@*;
    }
    return \@calls;
}

# The interpreter starts here and answers in _answers, so several texts run side by side.
sub _ask ( $self, $text, $calls ) {
    my $base = sprintf '%s/%d', $self->{directory}, ++$self->{count};
    _spew( "$base.pm", $text );
    _spew( "$base.calls", join q{}, map { join( "\t", $_->@* ) . "\n" } $calls->@* );
    open my $output, q{-|}, $^X, "$self->{directory}/evaluate.pl", "$base.pm", 'Known', $LIMIT, "$base.calls"
      or die "cannot start the evaluator: $!";
    return { output => $output, base => $base, calls => $calls };
}

sub _answers ($question) {
    chomp( my @outcomes = readline $question->{output} );
    close $question->{output} or die "the evaluator failed\n";
    unlink "$question->{base}.pm", "$question->{base}.calls";
    return \@outcomes;
}

sub _expect ($self) {
    my %line     = map { $_->{name} => $_ } $self->_cells;
    my $calls    = _calls( $self->_cells );
    my $outcomes = _answers( $self->_ask( $self->module('Known'), $calls ) );
    die "the original gives no value: @{$outcomes}\n"
      if @{$outcomes} != @{$calls} || grep { !/\Avalue / } $outcomes->@*;
    for my $index ( 0 .. $calls->$#* ) {
        my ( $name, @arguments ) = $calls->[$index]->@*;
        $line{$name}{expected}{"@arguments"} = $outcomes->[$index] =~ s/\Avalue //r;
    }
    return;
}

sub key ($mutant) {
    return join q{:}, $mutant->@{qw(line column end_line end_column replacement)};
}

sub _spliced ( $text, $mutant ) {
    my @lines  = split /^/, $text;
    my $offset = sub ( $line, $column ) {
        my $before = 0;
        $before += length $lines[$_] for 0 .. $line - 2;
        return $before + $column - 1;
    };
    my ( $start, $end ) =
      ( $offset->( $mutant->@{qw(line column)} ), $offset->( $mutant->@{qw(end_line end_column)} ) );
    return substr( $text, 0, $start ) . $mutant->{replacement} . substr $text, $end;
}

sub _line_of ( $self, $mutant ) {
    my $line = $mutant->{line} >= $FIRST_LINE ? $self->{lines}[ $mutant->{line} - $FIRST_LINE ] : undef;
    die 'the mutant ' . key($mutant) . " lies outside the cells\n" if !$line || $mutant->{end_line} != $mutant->{line};
    return $line;
}

# A cell is reached by the test that calls it, and the guard line by every test.
sub _question ( $self, $mutant ) {
    my $line     = $self->_line_of($mutant);
    my @reaching = $line->{kind} eq 'guard' ? $self->_cells : $line;
    return { $self->_ask( _spliced( $self->module('Known'), $mutant ), _calls(@reaching) )->%*, line => $line };
}

sub _outcome ( $self, $question ) {
    my $outcomes = _answers($question);
    return { map { $_ => 'does not compile' } $self->tests } if "@{$outcomes}" eq 'uncompiled';
    my $calls = $question->{calls};
    die "the evaluator gave @{$outcomes}\n" if @{$outcomes} != @{$calls};
    my %line    = map { $_->{name} => $_ } $self->_cells;
    my %outcome = map { $_         => $question->{line}{kind} eq 'guard' ? 'passes' : 'not reached' } $self->tests;
    for my $index ( 0 .. $calls->$#* ) {
        my ( $name, @arguments ) = $calls->[$index]->@*;
        my $test = $line{$name}{test};
        next if !defined $test || $outcome{$test} eq 'loops';
        my $got  = $outcomes->[$index];
        my $want = 'value ' . $line{$name}{expected}{"@arguments"};
        $outcome{$test} =
            $got eq 'looped'                            ? 'loops'
          : $got ne $want || $outcome{$test} eq 'kills' ? 'kills'
          :                                               'passes';
    }
    return \%outcome;
}

# A mutant that loops costs the whole time limit, so the mutants of a run are asked together.
sub prepare ( $self, $mutants ) {
    my %unknown = map { key($_) => $_ } grep { !$self->{truth}{ key($_) } } $mutants->@*;
    my @keys    = sort keys %unknown;
    while ( my @batch = splice @keys, 0, $TOGETHER ) {
        my %question = map { $_ => $self->_question( $unknown{$_} ) } @batch;
        $self->{truth}{$_} = $self->_outcome( $question{$_} ) for @batch;
    }
    return;
}

# What each test does to a mutant: kills, passes, not reached, does not compile, or loops.
sub truth ( $self, $mutant ) {
    $self->prepare( [$mutant] );
    return $self->{truth}{ key($mutant) };
}

# The status that the truth of a mutant gives, with the tests that kill it.
sub verdict ( $outcome, $coverage ) {
    my @tests = sort keys $outcome->%*;
    return ( 'CompileError', {} ) if grep { $outcome->{$_} eq 'does not compile' } @tests;
    my @reaching = $coverage eq 'file' ? @tests : grep { $outcome->{$_} ne 'not reached' } @tests;
    return ( 'NoCoverage', {} ) if !@reaching;
    my %killer = map { $_ => 1 } grep { $outcome->{$_} eq 'kills' } @reaching;
    return ( 'Killed',   \%killer ) if %killer;
    return ( 'Timeout',  {} )       if grep { $outcome->{$_} eq 'loops' } @reaching;
    return ( 'Survived', {} );
}

my $PLAIN = <<'PERL';
use Known;
sub value { my ( $cell, @arguments ) = @_; return scalar Known->can($cell)->(@arguments) }
PERL
my $FAILS = q[print "not ok $number - $cell\n";];

# A test in raw TAP that asserts its rows.
# `load` defines the function value in a loading style, and `wrong` is the code that answers a wrong value.
sub test_text ( $self, $test, %arg ) {
    my $first = defined $arg{first} ? "$arg{first}\n" : q{};
    my $load  = defined $arg{load}  ? $arg{load}      : $PLAIN;
    my $wrong = defined $arg{wrong} ? $arg{wrong}     : $FAILS;
    my $rows  = join q{}, map {
        sprintf "    [ %s, [ %s ], %s ],\n", quoted( $_->[0] ), join( ', ', map { quoted($_) } $_->[1]->@* ),
          quoted( $_->[2] )
    } $self->rows($test)->@*;
    return <<"PERL";
${first}use strict;
use warnings;
$load
my \@rows = (
$rows);
local \$| = 1;
print '1..', scalar \@rows, "\\n";
my \$number = 0;
for my \$row (\@rows) {
    my ( \$cell, \$arguments, \$want ) = \@{\$row};
    my \$got = value( \$cell, \@{\$arguments} );
    \$number++;
    if ( defined \$got && \$got eq \$want ) { print "ok \$number - \$cell\\n" }
    else { $wrong }
}
PERL
}

sub write ( $self, $project ) {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    $project->write( 'lib/Known.pm', $self->module('Known') );
    $project->write( $_,             $self->test_text($_) ) for $self->tests;
    return;
}

1;
