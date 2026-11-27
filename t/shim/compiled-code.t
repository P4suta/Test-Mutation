use strict;
use warnings;
use Test::More;
use File::Temp ();

# The run ignores an undetected mutant whose B::Deparse output equals the output of the original.
# The interpreter that runs the tests writes that output, so the rule must hold on every supported Perl.

my $dir   = File::Temp::tempdir( CLEANUP => 1 );
my $count = 0;

sub deparsed {
    my ($code) = @_;
    my $path   = sprintf '%s/%d.pm', $dir, ++$count;
    open my $handle, '>', $path or die "write $path: $!";
    print {$handle} $code or die "write $path: $!";
    close $handle         or die "close $path: $!";
    my $output = qx{"$^X" -MO=Deparse "$path" 2>/dev/null};
    return $? == 0 && length $output ? $output : undef;
}

sub distinct {
    my ( $name, $before, $after ) = @_;
    my ( $original, $mutant ) = map { deparsed($_) } $before, $after;
    ok defined $original,                        "$name compiles";
    ok !defined $mutant || $original ne $mutant, "$name shows the change";
    return;
}

sub filled {
    my ( $template, $marker, $text ) = @_;
    $template =~ s/\Q$marker\E/$text/;
    return $template;
}

my $plain   = "use strict;\nuse warnings;\nsub f { my (\$x, \$y, \@list) = \@_; BODY }\n1;\n";
my @changes = (
    [ 'an arithmetic operator', 'return $x + $y',                      'return $x - $y' ],
    [ 'a comparison boundary',  'return $x < $y',                      'return $x <= $y' ],
    [ 'a string comparison',    'return $x lt $y',                     'return $x le $y' ],
    [ 'a logical operator',     'return $x && $y',                     'return $x || $y' ],
    [ 'a defined-or',           'return $x // $y',                     'return $x || $y' ],
    [ 'a negation',             'return !$x',                          'return $x' ],
    [ 'a condition keyword',    'return 1 if $x; return 0',            'return 1 unless $x; return 0' ],
    [ 'a binding operator',     'return $x =~ /a/',                    'return $x !~ /a/' ],
    [ 'an increment',           '$x++; return $x',                     '$x--; return $x' ],
    [ 'a compound assignment',  '$x += $y; return $x',                 '$x -= $y; return $x' ],
    [ 'a return value',         'return $x',                           'return' ],
    [ 'a statement',            'push @list, $x; return @list',        'return @list' ],
    [ 'a loop control',         'for (@list) { next if $_; $x++ } $x', 'for (@list) { last if $_; $x++ } $x' ],
    [ 'a list function',        'push @list, $x; return @list',        'unshift @list, $x; return @list' ],
    [ 'a case function',        'return lc $x',                        'return uc $x' ],
    [ 'a number',               'return $x + 41',                      'return $x + 42' ],
    [ 'a string',               q{return 'abc'},                       q{return ''} ],
    [ 'an anchor',              'return $x =~ /^ab+c/',                'return $x =~ /ab+c/' ],
    [ 'a quantifier',           'return $x =~ /^ab+c/',                'return $x =~ /^ab*c/' ],
    [ 'a pattern flag',         'return $x =~ /abc/i',                 'return $x =~ /abc/' ],
    [ 'a sort order',           'return sort { $a <=> $b } @list',     'return reverse sort { $a <=> $b } @list' ],
    [ 'a range bound',          'return 1 .. $x',                      'return 1 .. -1 + $x' ],
    [ 'a folded constant',      'return 60 * 2',                       'return 60 / 2' ],
);
for my $change (@changes) {
    my ( $name, $before, $after ) = @{$change};
    distinct( $name, map { filled( $plain, 'BODY', $_ ) } $before, $after );
}

my @places = (
    [ 'a statement of the file',    'our $v; $v = EXPR; 1;' ],
    [ 'a lexical of the file',      'my $v = EXPR; sub f { $v } 1;' ],
    [ 'a package variable',         'our $v = EXPR; 1;' ],
    [ 'a localized variable',       'our $v; sub f { local $v = EXPR; g() } 1;' ],
    [ 'a BEGIN block',              'our $v; BEGIN { $v = EXPR } 1;' ],
    [ 'an INIT block',              'our $v; INIT { $v = EXPR } 1;' ],
    [ 'a CHECK block',              'our $v; CHECK { $v = EXPR } 1;' ],
    [ 'an END block',               'our $v; END { $v = EXPR } 1;' ],
    [ 'an anonymous sub in a hash', 'my %h = ( k => sub { EXPR } ); sub f { $h{k}->() } 1;' ],
    [ 'an anonymous sub',           'my $c = sub { EXPR }; sub f { $c->() } 1;' ],
    [ 'a closure',                  'sub f { my $x = shift; return sub { $x + EXPR } } 1;' ],
    [ 'a second package',           'package Inner; sub f { EXPR } package main; 1;' ],
    [ 'a sub with a prototype',     'sub f ($) { EXPR } 1;' ],
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
    [ 'a replacement expression',   'sub f { my $s = shift; $s =~ s/a/EXPR/e; $s } 1;' ],
    [ 'an overloaded operator',     'use overload q{+} => sub { EXPR }; 1;' ],
    [ 'a glob assignment',          '*f = sub { EXPR }; 1;' ],
    [ 'a bare block',               'our $v; { $v = EXPR; } 1;' ],
    [ 'a branch of the file',       'our $v; if ($v) { $v = EXPR } 1;' ],
    [ 'a state variable',           'use feature q{state}; sub f { state $v = EXPR; $v } 1;' ],
    [ 'a package block',            'package Inner { sub f { EXPR } } 1;',                             5.014 ],
    [ 'a lexical sub',              'use feature q{lexical_subs}; sub f { my sub g { EXPR } g() } 1;', 5.026 ],
    [ 'a signature default',        'use feature q{signatures}; sub f ($x = EXPR) { $x } 1;',          5.026 ],
);
for my $place (@places) {
    my ( $name, $template, $since ) = @{$place};
    next if $since && $] < $since;
    distinct( $name, map { filled( "no warnings;\n$template", 'EXPR', $_ ) } '$_[0] + 2', '$_[0] - 2' );
}

done_testing;
