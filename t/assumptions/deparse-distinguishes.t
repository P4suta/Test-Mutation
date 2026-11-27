use v5.36;
use Test2::V0;
use File::Temp ();

# The run ignores a survivor whose B::Deparse output equals the output of the original.
# That rule is sound when code with different behavior never produces equal output.
# B::Deparse prints neither a field nor an ADJUST block, so the analysis marks their sites as not comparable.

my $dir   = File::Temp::tempdir( CLEANUP => 1 );
my $count = 0;

sub deparsed ($code) {
    my $path = sprintf '%s/%d.pm', $dir, ++$count;
    open my $handle, '>', $path or die "write $path: $!";
    print {$handle} $code or die "write $path: $!";
    close $handle         or die "close $path: $!";
    my $output = qx{'$^X' -MO=Deparse '$path' 2>/dev/null};
    return $? == 0 && length $output ? $output : undef;
}

my $class =
  "use v5.38;\nuse experimental 'class';\nclass Counter {\n    field \$n = 0;\n    method up { BODY }\n}\n1;\n";
my $try = "use v5.36;\nuse feature 'try';\nno warnings;\nsub f { try { risky() } catch (\$e) { BODY } return 2 }\n1;\n";
my $defer = "use v5.36;\nuse feature 'defer';\nno warnings;\nour \$n;\nsub f { defer { BODY } return 1 }\n1;\n";
my $plain = "use strict;\nuse warnings;\nsub f { my (\$x, \$y, \@list) = \@_; BODY }\n1;\n";

my @different = (
    [ 'a method body',         $class, '$n = $n + 1; return $n',          '$n = $n - 1; return $n' ],
    [ 'a field read',          $class, 'return $n > 0',                   'return $n >= 0' ],
    [ 'a catch block',         $try,   'return 0',                        'return 1' ],
    [ 'a defer block',         $defer, '$n++',                            '$n--' ],
    [ 'a comparison boundary', $plain, 'return $x < $y',                  'return $x <= $y' ],
    [ 'a string comparison',   $plain, 'return $x lt $y',                 'return $x le $y' ],
    [ 'a defined-or',          $plain, 'return $x // $y',                 'return $x || $y' ],
    [ 'an anchor',             $plain, 'return $x =~ /^ab+c/',            'return $x =~ /ab+c/' ],
    [ 'a quantifier',          $plain, 'return $x =~ /^ab+c/',            'return $x =~ /^ab*c/' ],
    [ 'a pattern flag',        $plain, 'return $x =~ /abc/i',             'return $x =~ /abc/' ],
    [ 'a sort order',          $plain, 'return sort { $a <=> $b } @list', 'return reverse sort { $a <=> $b } @list' ],
    [ 'a range bound',         $plain, 'return 1 .. $x',                  'return 1 .. -1 + $x' ],
    [ 'a statement',           $plain, 'push @list, $x; return @list',    'return @list' ],
    [ 'a folded constant',     $plain, 'return 60 * 2',                   'return 60 / 2' ],
    [ 'a constant type',       $plain, 'return 60 * 1',                   'return 60 / 1' ],
    [ 'a close decimal',       $plain, 'return 0.1 + 0.2',                'return 0.3' ],
    [ 'a return value',        $plain, 'return $x',                       'return' ],
    [
        'a loop control',
        $plain,
        'for (@list) { next if $_; $x++ } return $x',
        'for (@list) { last if $_; $x++ } return $x'
    ],
    [ 'a condition keyword', $plain, 'return 1 if $x; return 0', 'return 1 unless $x; return 0' ],
    [ 'a string literal',    $plain, q{return 'abc'},            q{return ''} ],
);

for my $case (@different) {
    my ( $name, $template, $original, $mutated ) = $case->@*;
    next if $template eq $class && $] < 5.038;
    my ( $before, $after ) = map { deparsed( $template =~ s/BODY/$_/r ) } $original, $mutated;
    ok defined $before && defined $after, "$name compiles before and after the change";
    isnt $after, $before, "$name stays distinct";
}

# Every place that holds a site must reach the output, whatever construct surrounds it.
my $head = "use v5.36;\nno warnings;\nuse feature qw(defer try);\n" . ( $] >= 5.038 ? "use feature 'class';\n" : q{} );
my @contexts = (
    [ 'a statement of the file',    'our $v; $v = EXPR; 1;' ],
    [ 'a lexical of the file',      'my $v = EXPR; sub f { $v } 1;' ],
    [ 'a package variable',         'our $v = EXPR; 1;' ],
    [ 'a state variable',           'sub f { state $v = EXPR; $v } 1;' ],
    [ 'a localized variable',       'our $v; sub f { local $v = EXPR; g() } 1;' ],
    [ 'a BEGIN block',              'our $v; BEGIN { $v = EXPR } 1;' ],
    [ 'an INIT block',              'our $v; INIT { $v = EXPR } 1;' ],
    [ 'a CHECK block',              'our $v; CHECK { $v = EXPR } 1;' ],
    [ 'a UNITCHECK block',          'our $v; UNITCHECK { $v = EXPR } 1;' ],
    [ 'an END block',               'our $v; END { $v = EXPR } 1;' ],
    [ 'a lexical sub',              'sub f { my sub g { EXPR } g() } 1;' ],
    [ 'a state sub',                'sub f { state sub g { EXPR } g() } 1;' ],
    [ 'an anonymous sub in a hash', 'my %h = ( k => sub { EXPR } ); sub f { $h{k}->() } 1;' ],
    [ 'an anonymous sub',           'my $c = sub { EXPR }; sub f { $c->() } 1;' ],
    [ 'a closure',                  'sub f { my $x = shift; return sub { $x + EXPR } } 1;' ],
    [ 'a package block',            'package Inner { sub f { EXPR } } 1;' ],
    [ 'a second package',           'package Inner; sub f { EXPR } package main; 1;' ],
    [ 'a sub with a prototype',     'sub f :prototype($) { EXPR } 1;' ],
    [ 'a signature default',        'sub f ($x = EXPR) { $x } 1;' ],
    [ 'a sort block',               'sub f { sort { $a <=> $b + EXPR } @_ } 1;' ],
    [ 'a map block',                'sub f { map { $_ + EXPR } @_ } 1;' ],
    [ 'a grep block',               'sub f { grep { $_ > EXPR } @_ } 1;' ],
    [ 'a do block',                 'sub f { my $v = do { EXPR }; $v } 1;' ],
    [ 'an eval block',              'sub f { eval { EXPR } } 1;' ],
    [ 'a ternary',                  'sub f { $_[0] ? EXPR : 9 } 1;' ],
    [ 'a hash value',               'sub f { return { k => EXPR } } 1;' ],
    [ 'a subscript',                'sub f { $_[EXPR] } 1;' ],
    [ 'a loop list',                'sub f { my $t = 0; for my $i ( 1 .. EXPR ) { $t += $i } $t } 1;' ],
    [ 'a loop condition',           'sub f { my $i = 0; while ( $i < EXPR ) { $i++ } $i } 1;' ],
    [ 'a counting loop',            'sub f { my $t; for ( my $i = 0; $i < EXPR; $i++ ) { $t++ } $t } 1;' ],
    [ 'a statement modifier',       'sub f { my $t; $t += $_ for 1 .. EXPR; $t } 1;' ],
    [ 'a method argument',          'sub f { main->g(EXPR) } 1;' ],
    [ 'a destructor',               'sub DESTROY { EXPR } 1;' ],
    [ 'a try block',                'sub f { try { EXPR } catch ($e) { 0 } } 1;' ],
    [ 'a finally block',            'sub f { try { 1 } catch ($e) { 0 } finally { g(EXPR) } } 1;' ],
    [ 'a defer block',              'sub f { defer { g(EXPR) } 1 } 1;' ],
    [ 'a replacement expression',   'sub f { my $s = shift; $s =~ s/a/EXPR/e; $s } 1;' ],
    [ 'a pattern code block',       'sub f { $_[0] =~ /a(?{ EXPR })/ } 1;' ],
    [ 'an overloaded operator',     'use overload q{+} => sub { EXPR }; 1;' ],
    [ 'a glob assignment',          '*f = sub { EXPR }; 1;' ],
    [ 'a bare block',               'our $v; { $v = EXPR; } 1;' ],
    [ 'a branch of the file',       'our $v; if ($v) { $v = EXPR } 1;' ],
    [ 'a class method',             'class C { method m { EXPR } } 1;',                             5.038 ],
    [ 'a class sub',                'class C { sub s { EXPR } } 1;',                                5.038 ],
    [ 'a class statement',          'class C { our $v; $v = EXPR; } 1;',                            5.038 ],
    [ 'a method signature',         'class C { method m ($y = EXPR) { $y } } 1;',                   5.038 ],
    [ 'an anonymous method',        'class C { field $x; method m { return method { EXPR } } } 1;', 5.038 ],
);

for my $context (@contexts) {
    my ( $name, $template, $since ) = $context->@*;
    next if $since && $] < $since;
    my ( $before, $after ) = map { deparsed( $head . $template =~ s/EXPR/$_/r ) } '$_[0] + 2', '$_[0] - 2';
    ok defined $before && defined $after, "$name compiles before and after the change";
    isnt $after, $before, "$name shows a change";
}

my @equal = (
    [
        'a comparison that folds to the same value',
        q{return 10 > 5 ? 'big' : 'small'},
        q{return 10 >= 5 ? 'big' : 'small'}
    ],
    [ 'a double negation of a condition', 'return 1 unless !$x; return 0', 'return 1 if $x; return 0' ],
);

for my $case (@equal) {
    my ( $name, $original, $mutated ) = $case->@*;
    my ( $before, $after ) = map { deparsed( $plain =~ s/BODY/$_/r ) } $original, $mutated;
    ok defined $before, "$name compiles";
    is $after, $before, "$name compares equal";
}

done_testing;
