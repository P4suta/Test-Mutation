use v5.36;
use Test2::V0;
use File::Temp ();

# The run ignores a survivor whose B::Deparse output equals the output of the original.
# That rule is sound when code with different behavior never produces equal output.

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
    my ( $before, $after ) = map { deparsed( $template =~ s/BODY/$_/r ) } $original, $mutated;
    ok defined $before,                      "$name compiles";
    ok !defined $after || $before ne $after, "$name stays distinct";
}

my @equal = (
    [ 'a constant that folds to the same value', 'return 60 + 0',                 'return 60 - 0' ],
    [ 'a double negation of a condition',        'return 1 unless !$x; return 0', 'return 1 if $x; return 0' ],
);

for my $case (@equal) {
    my ( $name, $original, $mutated ) = $case->@*;
    my ( $before, $after ) = map { deparsed( $plain =~ s/BODY/$_/r ) } $original, $mutated;
    ok defined $before, "$name compiles";
    is $after, $before, "$name compares equal";
}

done_testing;
