use v5.36;
use Test2::V0;
use Permutl::Source;
use Permutl::Syntax::PPI;

sub analyze ($code) {
    my $source = Permutl::Source->new( path => 'lib/X.pm', text => $code, encoding => 'UTF-8' );
    return Permutl::Syntax::PPI::analyze($source);
}

sub sites_of ( $code, $kind ) {
    return [ grep { $_->kind eq $kind } analyze($code)->{sites}->@* ];
}

sub summary ( $code, $kind ) {
    return [ map { [ $_->text, $_->role ] } sites_of( $code, $kind )->@* ];
}

subtest 'every site addresses its own text' => sub {
    my $code     = "use v5.36;\nsub f (\$x) {\n    return \$x + 1 if \$x > 0;\n    return -\$x;\n}\n";
    my $analysis = analyze($code);
    is $analysis->{problem}, undef, 'no problem';
    my @wrong = grep { substr( $code, $_->start, $_->end - $_->start ) ne $_->text } $analysis->{sites}->@*;
    is \@wrong, [], 'text equals the span';
    ok scalar( $analysis->{sites}->@* ), 'sites exist';
};

subtest 'operators carry a role' => sub {
    is summary( 'my $y = $a + $b - -$c; $y++; my $z = !$y;', 'operator' ),
      [
        [ '=',  'binary' ],
        [ '+',  'binary' ],
        [ '-',  'binary' ],
        [ '-',  'unary' ],
        [ '++', 'update' ],
        [ '=',  'binary' ],
        [ '!',  'unary' ]
      ],
      'binary, unary, and update operators';
    is summary( 'return - $x;', 'operator' ), [ [ '-', 'unary' ] ], 'minus after return is unary';
    is [ map { $_->detail->{operand} } sites_of( '$a =~ /x/; $b =~ s/x/y/; $c !~ $re;', 'operator' )->@* ],
      [ 'match', 'substitute', 'match' ], 'binding operators name their operand';
};

subtest 'words carry a role and data words are left out' => sub {
    is summary( 'if ($x) { push @a, max(1, 2) } foo() unless $y; last if $z;', 'word' ),
      [
        [ 'if',     'compound' ],
        [ 'push',   'call' ],
        [ 'max',    'call' ],
        [ 'foo',    'call' ],
        [ 'unless', 'modifier' ],
        [ 'last',   'control' ],
        [ 'if',     'modifier' ]
      ],
      'compound keyword, calls, modifiers, loop control';
    is summary( 'my %h = ( max => 1 ); $h{min}; $obj->push(1); Foo::Bar->new; sub lc { 1 }', 'word' ),
      [],
      'declarators, hash keys, subscripts, method names, class names, and sub names produce no site';
};

subtest 'excluded regions produce no sites' => sub {
    is analyze("use constant X => 1 + 2;\nno warnings;\npackage Foo;\nour \$VERSION = '1.2' + 0;\n")->{sites}, [],
      'use, no, package, and $VERSION statements';
    is summary( "1;\n__END__\nmy \$x = 1 + 2;\n", 'operator' ), [], 'text after __END__';
    is summary( "=pod\n\n1 + 2\n\n=cut\n\n# 3 + 4\nmy \$s = '5 + 6';\n", 'operator' ), [ [ '=', 'binary' ] ],
      'POD, comments, and string contents';
    is summary( "my \$t = <<~EOT;\n    1 + 2\n    EOT\nmy \$u = 3 - 4;\n", 'operator' ),
      [ [ '=', 'binary' ], [ '=', 'binary' ], [ '-', 'binary' ] ], 'heredoc bodies';
};

subtest 'structural sites' => sub {
    my $code = <<'PERL';
sub total {
    my ($list) = @_;
    my $sum = 0;
    log_call('total');
    for my $n (@$list) {
        $sum += $n;
    }
    return 0 if !@$list;
    return $sum;
}
PERL
    is [ map { $_->text } sites_of( $code, 'statement' )->@* ], [ q{log_call('total');}, '$sum += $n;' ],
      'expression statements are deletable, declarations and returns are not';
    is [ map { [ $_->text, $_->detail->{literal} ] } sites_of( $code, 'return' )->@* ],
      [ [ '0', '0' ], [ '$sum', undef ] ],
      'return expressions stop before a modifier';
    my ($body) = sites_of( $code, 'sub_body' )->@*;
    is $body->detail->{name}, 'total',   'the sub body is named';
    is $body->scope,          [ 1, 10 ], 'the sub body scope is the whole sub';
    like $body->text, qr/\A\n    my \(\$list\).*return \$sum;\n\z/s, 'the body span is inside the braces';
    is [ map { [ $_->text, $_->detail->{keyword} ] }
          sites_of( 'if ( $a > 1 ) { f() } elsif ($b) { g() } while ($c) { h() }', 'condition' )->@* ],
      [ [ ' $a > 1 ', 'if' ], [ '$b', 'elsif' ], [ '$c', 'while' ] ], 'conditions';
};

subtest 'statements that must stay are not deletable' => sub {
    is [ map { $_->text }
          sites_of( "1;\n'done';\nmy \$x = f();\nfield \$y = 1;\nADJUST { f() } method name { g() }\n", 'statement' )
          ->@* ],
      [ 'f()', 'g()' ], 'literals, declarations, fields, and block-bearing statements stay';
};

subtest 'class syntax yields method bodies' => sub {
    my $code =
      "use v5.38;\nclass P {\n    field \$x :param = 0;\n    method move (\$dx) {\n        \$x += \$dx;\n        return \$self;\n    }\n    method x { \$x }\n}\n";
    is [ map { [ $_->detail->{name}, $_->scope ] } sites_of( $code, 'sub_body' )->@* ],
      [ [ 'move', [ 4, 7 ] ], [ 'x', [ 8, 8 ] ] ], 'method bodies with their line ranges';
};

subtest 'a class body is a code block whatever its header holds' => sub {
    my $code = <<'PERL';
class Counter 1.0 {
    field $step = 1 + 1;
    register('counter');
}
class Other :isa(Counter) {
    field $size = 2 * 2;
}
class Third 2.0 :isa(Other) {
    field $rate = 3 - 3;
}
PERL
    my %scope = map { $_->text => $_->scope } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@*;
    is $scope{'+'}, [ 2, 2 ], 'a field of a class with a version';
    is $scope{'*'}, [ 6, 6 ], 'a field of a class with an attribute';
    is $scope{'-'}, [ 9, 9 ], 'a field of a class with both';
    is [ map { $_->text } sites_of( $code, 'statement' )->@* ], [q{register('counter');}],
      'a call in the class body is deletable';
};

subtest 'every named body of a class is a body site' => sub {
    my $code = <<'PERL';
class Counter {
    ADJUST {
        setup();
    }
    method bump :lvalue ($by = 1) { $count }
    sub helper { return 1 }
    method read { $count }
    my $anonymous = method { 2 };
}
PERL
    is [ map { [ $_->detail->{name}, $_->scope, $_->text ] } sites_of( $code, 'sub_body' )->@* ],
      [
        [ 'ADJUST', [ 2, 4 ], "\n        setup();\n    " ],
        [ 'bump',   [ 5, 5 ], ' $count ' ],
        [ 'helper', [ 6, 6 ], ' return 1 ' ],
        [ 'read',   [ 7, 7 ], ' $count ' ],
      ],
      'the adjust block, a method with an attribute, and a sub that follows a method';
};

subtest 'declaration headers produce no sites' => sub {
    my $code = <<'PERL';
class Counter 1.0 :isa(Base) {
    field $count :param :reader = 0;
    field $name :param(label) //= 'none';
    method bump :lvalue ($by = 1) { $count }
}
class Plain 2.0;
role Shared;
PERL
    is [ map { [ $_->kind, $_->text ] } grep { $_->kind ne 'sub_body' } analyze($code)->{sites}->@* ],
      [
        [ 'operator',  q{=} ],
        [ 'number',    '0' ],
        [ 'operator',  '//=' ],
        [ 'string',    q{'none'} ],
        [ 'operator',  q{=} ],
        [ 'number',    '1' ],
        [ 'statement', '$count' ],
      ],
      'the initializers, the signature, and the bodies remain';
};

subtest 'code after a block that PPI leaves open is its own statement' => sub {
    my $code = <<'PERL';
sub f {
    try { g() } catch ($e) { h() }
    finally {
        i();
    }
    after_finally( 1 + 2 );
    defer { j() }
    after_defer( 3 - 4 );
    last_call();
}
method name {
    k();
}
after_method( 5 * 6 );
PERL
    is [ map { [ $_->text, $_->scope ] } grep { $_->text =~ /after|last/ } sites_of( $code, 'statement' )->@* ],
      [
        [ 'after_finally( 1 + 2 );', [ 6,  6 ] ],
        [ 'after_defer( 3 - 4 );',   [ 8,  8 ] ],
        [ 'last_call();',            [ 9,  9 ] ],
        [ 'after_method( 5 * 6 );',  [ 14, 14 ] ],
      ],
      'the statement after the block is deletable';
    my %scope = map { $_->text => $_->scope } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@*;
    is $scope{'+'}, [ 6,  6 ],  'an operator after a finally block';
    is $scope{'-'}, [ 8,  8 ],  'an operator after a defer block';
    is $scope{'*'}, [ 14, 14 ], 'an operator after a method';
};

subtest 'scope is the statement that runs the site' => sub {
    my $code = <<'PERL';
sub f {
    my $x = g(
        1 + 2,
        [ 3 * 4 ],
    );
    my @sorted = sort {
        $a <=> $b
    } @list;
    if ( $x > 1 ) {
        h( 5 - 6 );
    }
    my %h = map {
        $_ => 7 / 8
    } @list;
    return {
        total => 9 % 10,
    };
}
PERL
    my %scope = map { $_->text => $_->scope } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@*;
    is $scope{'+'},   [ 2,  5 ],  'an argument on a later line belongs to the whole statement';
    is $scope{'*'},   [ 2,  5 ],  'a nested constructor belongs to the whole statement';
    is $scope{'<=>'}, [ 6,  8 ],  'a sort block belongs to the sort statement';
    is $scope{'>'},   [ 9,  11 ], 'a condition belongs to its compound statement';
    is $scope{'-'},   [ 10, 10 ], 'a statement in a branch has its own scope';
    is $scope{'/'},   [ 13, 13 ], 'a map block runs its own statement';
    is $scope{'%'},   [ 15, 17 ], 'an anonymous hash belongs to the return statement';
};

subtest 'suppression comments become line ranges' => sub {
    my $code = join "\n",
      'my $a = 1 + 2;    ## no mutate',
      '## no mutate (arithmetic, comparison)',
      'my $b = 3 + 4;',
      '## use mutate',
      'my $c = 5 + 6;',
      '## no mutate',
      'my $d = 7 + 8;',
      q{};
    is analyze($code)->{suppressions},
      [
        { first => 1, last => 1,     names => undef },
        { first => 2, last => 4,     names => [ 'arithmetic', 'comparison' ] },
        { first => 6, last => undef, names => undef },
      ],
      'trailing, bounded, and open-ended ranges';
};

subtest 'files that cannot be analyzed report a problem' => sub {
    like analyze("my \$x = 1;\r\n")->{problem}, qr/carriage returns/, 'carriage returns';
    is analyze("my \$x = 1;\r\n")->{sites}, [], 'no sites';
};

done_testing;
