package Discovery::Streams;
use v5.36;

# TAP streams from a small grammar: one choice on each axis, where the first value of an axis is the plain one.
# A stream with one choice away from the plain stream names the axis value that a disagreement belongs to.

my @AXES = (
    [ version => [qw(none thirteen twelve fourteen late)] ],
    [ plan    => [qw(first last missing twice middle tail-text skip-all)] ],
    [ count   => [qw(exact more fewer)] ],
    [ numbers => [qw(order swapped gap none twice)] ],
    [
        result => [
            qw(ok not-ok todo todo-lower todo-mixed todo-tight todo-passes todo-after-hash todone escaped-todo),
            qw(skip skip-lower skip-mixed skip-fails skip-then-todo),
        ]
    ],
    [ nested  => [qw(none passing inner-fails outer-fails inner-bails inner-plan)] ],
    [ bail    => [qw(none end middle lower)] ],
    [ garbage => [qw(none after before comment blank okay upper)] ],
    [ ending  => [qw(lf crlf)] ],
    [ final   => [qw(newline none)] ],
);

my %VERSION = ( thirteen => 13, twelve => 12, fourteen => 14 );
my %PLANNED = ( exact    => 3,  more   => 4,  fewer    => 2 );
my %NUMBERS = (
    order   => [ 1,   2,   3 ],
    swapped => [ 1,   3,   2 ],
    gap     => [ 1,   2,   4 ],
    none    => [ q{}, q{}, q{} ],
    twice   => [ 1,   2,   2 ]
);
my %RESULT = (
    'ok'              => 'ok%s - second',
    'not-ok'          => 'not ok%s - second',
    'todo'            => 'not ok%s - second # TODO later',
    'todo-lower'      => 'not ok%s - second # todo later',
    'todo-mixed'      => 'not ok%s - second # ToDo later',
    'todo-tight'      => 'not ok%s - second #TODO',
    'todo-passes'     => 'ok%s - second # TODO later',
    'todo-after-hash' => 'not ok%s - issue # 12 # TODO later',
    'todone'          => 'not ok%s - second # TODONE',
    'escaped-todo'    => 'not ok%s - second \\# TODO later',
    'skip'            => 'ok%s - second # SKIP no need',
    'skip-lower'      => 'ok%s # skip no need',
    'skip-mixed'      => 'ok%s # Skip no need',
    'skip-fails'      => 'not ok%s - second # SKIP no need',
    'skip-then-todo'  => 'not ok%s - second # SKIP no need # TODO later',
);
my %NESTED = (
    'none'        => [],
    'passing'     => [ '    ok 1 - inner',     '    1..1' ],
    'inner-fails' => [ '    not ok 1 - inner', '    1..1' ],
    'outer-fails' => [ '    ok 1 - inner',     '    1..1' ],
    'inner-bails' => ['    Bail out! inside'],
    'inner-plan'  => ['    1..7'],
);
my %BETWEEN = ( comment => '# a diagnostic line',  blank => q{}, okay => 'okay 2 - no test line' );
my %LAST    = ( end     => 'Bail out! at the end', lower => 'bail out! in lower case' );
my $NO_TAP  = 'this line is no TAP';

sub axes () {
    return map { $_->[0] } @AXES;
}

sub values_of ($axis) {
    my ($values) = map { $_->[1] } grep { $_->[0] eq $axis } @AXES;
    return $values->@*;
}

sub _plain () {
    return map { $_->[0] => $_->[1][0] } @AXES;
}

sub _numbered ($number) {
    return length $number ? " $number" : q{};
}

sub text (%choice) {
    my %plain   = _plain();
    my @unknown = grep { !exists $plain{$_} } sort keys %choice;
    die "the grammar has no axis named @unknown\n" if @unknown;
    my %at      = ( %plain, %choice );
    my $ending  = $at{ending} eq 'crlf'    ? "\r\n"                                 : "\n";
    my @version = $VERSION{ $at{version} } ? "TAP version $VERSION{ $at{version} }" : ();
    return join q{}, map { $_ . $ending } @version, '1..0 # SKIP nothing to test' if $at{plan} eq 'skip-all';

    my $plan    = "1..$PLANNED{ $at{count} }" . ( $at{plan} eq 'tail-text' ? ' and more' : q{} );
    my @numbers = map { _numbered($_) } $NUMBERS{ $at{numbers} }->@*;
    my $varied  = sprintf $RESULT{ $at{result} }, $numbers[1];
    $varied =~ s/\Aok/not ok/ if $at{nested} eq 'outer-fails';
    my %first = map { $_ => 1 } qw(first twice tail-text);
    my @lines = (
        @version,
        ( $at{garbage} eq 'before' ? $NO_TAP : () ),
        ( $first{ $at{plan} }      ? $plan   : () ),
        "ok$numbers[0] - first",
        ( $at{version} eq 'late'          ? 'TAP version 13'          : () ),
        ( $at{plan} eq 'middle'           ? $plan                     : () ),
        ( $at{bail} eq 'middle'           ? 'Bail out! in the middle' : () ),
        ( exists $BETWEEN{ $at{garbage} } ? $BETWEEN{ $at{garbage} }  : () ),
        $NESTED{ $at{nested} }->@*,
        $varied,
        ( $at{garbage} eq 'upper'                     ? 'OK'               : 'ok' ) . "$numbers[2] - third",
        ( $at{plan} eq 'last' || $at{plan} eq 'twice' ? $plan              : () ),
        ( exists $LAST{ $at{bail} }                   ? $LAST{ $at{bail} } : () ),
        ( $at{garbage} eq 'after'                     ? $NO_TAP            : () ),
    );
    my $text = join q{}, map { $_ . $ending } @lines;
    $text =~ s/\r?\n\z// if $at{final} eq 'none';
    return $text;
}

sub _case (@parts) {
    return {
        parts => [@parts],
        label => @parts ? join( q{ }, @parts ) : 'the plain stream',
        text  => text( map { split /=/, $_, 2 } @parts ),
    };
}

sub _choices () {
    my @choices;
    for my $axis (@AXES) {
        my ( $name, $values ) = $axis->@*;
        push @choices, map { "$name=$_" } $values->@[ 1 .. $values->$#* ];
    }
    return @choices;
}

sub _axis ($choice) {
    return ( split /=/, $choice )[0];
}

sub _combinations ( $count, $choices, $from, @chosen ) {
    return _case(@chosen) if @chosen == $count;
    my %taken = map { _axis($_) => 1 } @chosen;
    return map { _combinations( $count, $choices, $_ + 1, @chosen, $choices->[$_] ) }
      grep { !$taken{ _axis( $choices->[$_] ) } } $from .. $choices->$#*;
}

# Every stream with the given number of choices away from the plain one, each on an axis of its own.
sub with_choices ($count) {
    return _combinations( $count, [ _choices() ], 0 );
}

1;
