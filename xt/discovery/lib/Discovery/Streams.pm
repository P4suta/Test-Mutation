package Discovery::Streams;
use v5.36;

# TAP streams from a small grammar: one choice on each axis, where the first value of an axis is the plain one.
# A stream with one choice away from the plain stream names the axis value that a disagreement belongs to.

my @AXES = (
    [ version => [qw(none thirteen twelve fourteen late fifteen lower twice after-comment)] ],
    [ pragma  => [qw(none strict strict-off strict-list strict-bare ignore-exit)] ],
    [
        plan => [
            qw(first last missing twice middle tail-text skip-all),
            qw(todo-list skip-text skip-all-bare skip-all-text)
        ]
    ],
    [ count   => [qw(exact more fewer)] ],
    [ numbers => [qw(order swapped gap none twice padded from-zero)] ],
    [
        result => [
            qw(ok not-ok todo todo-lower todo-mixed todo-tight todo-passes todo-after-hash todone escaped-todo),
            qw(skip skip-lower skip-mixed skip-fails skip-then-todo escaped-backslash todo-without-hash),
        ]
    ],
    [ block   => [qw(none yaml yaml-bail yaml-open yaml-broken yaml-short)] ],
    [ nested  => [qw(none passing inner-fails outer-fails inner-bails inner-plan)] ],
    [ bail    => [qw(none end middle lower)] ],
    [ garbage => [qw(none after before comment blank okay upper blank-last)] ],
    [ ending  => [qw(lf crlf)] ],
    [ final   => [qw(newline none)] ],
);

# The lines of a version: one that TAP::Parser accepts, one below and one above its range, and the places it refuses.
my %VERSION = (
    'thirteen'      => ['TAP version 13'],
    'twelve'        => ['TAP version 12'],
    'fourteen'      => ['TAP version 14'],
    'fifteen'       => ['TAP version 15'],
    'lower'         => ['tap version 13'],
    'twice'         => [ 'TAP version 13',       'TAP version 13' ],
    'after-comment' => [ '# before the version', 'TAP version 13' ],
);

# A pragma is a line of version 13, and a stream of version 12 holds it as a line of no kind.
# The strict pragma turns a line of no kind into an error, so three of the values bring such a line with them.
my $NO_TAP = 'this line is no TAP';
my %PRAGMA = (
    'strict'      => [ 'pragma +strict',          $NO_TAP ],
    'strict-off'  => [ 'pragma +strict',          'pragma -strict', $NO_TAP ],
    'strict-list' => [ 'pragma -strict, +strict', $NO_TAP ],
    'strict-bare' => ['pragma +strict'],
    'ignore-exit' => ['pragma +ignore_exit'],
);
my %PLANNED = ( exact => 3, more => 4, fewer => 2 );

# What follows the count on the line of a plan, and the plans that stand for a whole stream.
my %PLAN_TAIL = ( 'tail-text' => ' and more', 'todo-list' => ' todo 2', 'skip-text' => ' # SKIP later' );
my %PLAN_ONLY =
  ( 'skip-all' => '1..0 # SKIP nothing to test', 'skip-all-bare' => '1..0', 'skip-all-text' => '1..0 no reason' );
my %PLAN_FIRST = map { $_ => 1 } qw(first twice tail-text todo-list skip-text);
my %NUMBERS    = (
    'order'     => [ 1,    2,    3 ],
    'swapped'   => [ 1,    3,    2 ],
    'gap'       => [ 1,    2,    4 ],
    'none'      => [ q{},  q{},  q{} ],
    'twice'     => [ 1,    2,    2 ],
    'padded'    => [ '01', '02', '03' ],
    'from-zero' => [ 0,    1,    2 ],
);
my %RESULT = (
    'ok'                => 'ok%s - second',
    'not-ok'            => 'not ok%s - second',
    'todo'              => 'not ok%s - second # TODO later',
    'todo-lower'        => 'not ok%s - second # todo later',
    'todo-mixed'        => 'not ok%s - second # ToDo later',
    'todo-tight'        => 'not ok%s - second #TODO',
    'todo-passes'       => 'ok%s - second # TODO later',
    'todo-after-hash'   => 'not ok%s - issue # 12 # TODO later',
    'todone'            => 'not ok%s - second # TODONE',
    'escaped-todo'      => 'not ok%s - second \\# TODO later',
    'skip'              => 'ok%s - second # SKIP no need',
    'skip-lower'        => 'ok%s # skip no need',
    'skip-mixed'        => 'ok%s # Skip no need',
    'skip-fails'        => 'not ok%s - second # SKIP no need',
    'skip-then-todo'    => 'not ok%s - second # SKIP no need # TODO later',
    'escaped-backslash' => 'not ok%s - second \\\\# TODO later',
    'todo-without-hash' => 'not ok%s - second TODO later',
);

# A block of diagnostics after the first test: version 13 reads it as one YAML document, and version 12 line by line.
my %BLOCK = (
    'none'        => [],
    'yaml'        => [ '  ---', '  message: fine', '  ...' ],
    'yaml-bail'   => [ '  ---', '  message: |',    '    Bail out! is text', '  ...' ],
    'yaml-open'   => [ '  ---', '  message: fine' ],
    'yaml-broken' => [ '  ---', '  no key', '  ...' ],
    'yaml-short'  => [ '  ---', '  message: fine', ' level: one', '  ...' ],
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

sub _lines ( $table, $choice ) {
    return @{ $table->{$choice} || [] };
}

sub text (%choice) {
    my %plain   = _plain();
    my @unknown = grep { !exists $plain{$_} } sort keys %choice;
    die "the grammar has no axis named @unknown\n" if @unknown;
    my %at     = ( %plain, %choice );
    my $ending = $at{ending} eq 'crlf' ? "\r\n" : "\n";
    my @head   = ( _lines( \%VERSION, $at{version} ), _lines( \%PRAGMA, $at{pragma} ) );
    return join q{}, map { $_ . $ending } @head, $PLAN_ONLY{ $at{plan} } if $PLAN_ONLY{ $at{plan} };

    my $plan    = "1..$PLANNED{ $at{count} }" . ( $PLAN_TAIL{ $at{plan} } || q{} );
    my @numbers = map { _numbered($_) } $NUMBERS{ $at{numbers} }->@*;
    my $varied  = sprintf $RESULT{ $at{result} }, $numbers[1];
    $varied =~ s/\Aok/not ok/ if $at{nested} eq 'outer-fails';
    my @lines = (
        @head,
        ( $at{garbage} eq 'before' ? $NO_TAP : () ),
        ( $PLAN_FIRST{ $at{plan} } ? $plan   : () ),
        "ok$numbers[0] - first",
        _lines( \%BLOCK, $at{block} ),
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
        ( $at{garbage} eq 'blank-last'                ? q{}                : () ),
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

# Bytes above ASCII in the plain stream, each in one place where the rules of characters decide a line.
# prove decodes the lines after a version line of 13 or 14 from UTF-8, and it reads the bytes of every other stream.
my %BYTES = (
    'none'              => sub ($text) { return $text },
    'letter-after-ok'   => sub ($text) { return $text =~ s/^ok 2/ok\xC3\xA9 2/mr },
    'symbol-after-ok'   => sub ($text) { return $text =~ s/^ok 2/ok\xE2\x86\x92 2/mr },
    'invalid-after-ok'  => sub ($text) { return $text =~ s/^ok 2/ok\xE9 2/mr },
    'digit-after-ok'    => sub ($text) { return $text =~ s/^ok 2/ok \xD9\xA3/mr },
    'space-after-count' => sub ($text) { return $text =~ s/^1[.][.]3$/1..3\xC2\xA0/mr },
    'space-before-bail' => sub ($text) { return $text =~ s/\z/\xC2\xA0Bail out! after a space\n/r },
    'yaml-key' => sub ($text) { return $text =~ s/^(ok 1 - first\n)/$1  ---\n  \xC3\xA9t\xC3\xA9: 1\n  ...\n/mr },
    'invalid-comment' => sub ($text) { return $text =~ s/^(ok 1 - first\n)/$1# \xFF\xFE\n/mr },
    'text-in-name'    => sub ($text) { return $text =~ s/^ok 2 - second$/ok 2 - caf\xC3\xA9/mr },
);

sub encoded () {
    my @cases;
    for my $version (qw(none thirteen fourteen)) {
        for my $bytes ( sort keys %BYTES ) {
            my @parts =
              ( ( $version eq 'none' ? () : "version=$version" ), ( $bytes eq 'none' ? () : "bytes=$bytes" ) );
            push @cases,
              {
                parts => \@parts,
                label => @parts ? join( q{ }, @parts ) : 'the plain stream',
                text  => $BYTES{$bytes}->( text( version => $version ) ),
              };
        }
    }
    return @cases;
}

1;
