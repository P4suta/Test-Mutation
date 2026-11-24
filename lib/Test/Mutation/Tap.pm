package Test::Mutation::Tap;
use v5.36;
use Types::Standard qw(ArrayRef Bool Dict Enum HashRef Int Maybe Num Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

# The phases of a stream, after the states of TAP::Parser: what the lines so far allow the next line to be.
my @PHASES = qw(start versioned planned unplanned closed failed);

my $STATE = Dict [
    grammar     => Enum [ 12, 13 ],
    phase       => Enum [@PHASES],
    planned     => Maybe [Num],
    seen        => Int,
    todo        => HashRef [Bool],
    strict      => Bool,
    ignore_exit => Bool,
    bailed      => Bool,
    blank       => Bool,
    block       => Maybe [ Dict [ width => Int, lines => ArrayRef [Str] ] ],
    rest        => Str,
];

# TAP::Parser::Grammar matches bytes, and this file would match Unicode, so each pattern keeps to ASCII.
# A directive stands behind the first hash that no backslash escapes, and TODO alone changes a verdict.
my $RESULT  = qr/\A(not[ ])?ok\b\s*([0-9]+)?\s*/aa;
my $TODO    = qr{ [^\\\#]* (?: \\. [^\\\#]* )* [#] \s* (?i: TODO ) \b }xaa;
my $TEST    = qr/$RESULT($TODO)?/aa;
my $COMMENT = qr/\A[#]/;

# Version 12 takes any text after a plan of no tests, and a list of unfinished tests after another plan.
# Each of the three forms gives the count and the list, and the first form that matches is the plan.
my $NO_TESTS     = qr/(0+)(?![0-9])().*/aa;
my $WITH_A_LIST  = qr/([0-9]+)\s*todo((?:\s+[0-9]+)+).*/aa;
my $COUNT_ALONE  = qr/([0-9]+)()\s*/aa;
my $PLAN_12      = qr{ \A 1[.][.] (?| $NO_TESTS | $WITH_A_LIST | $COUNT_ALONE ) \z }xaa;
my $PLAN_13      = qr{ \A 1[.][.] ([0-9]+) () \s* (?: [#] \s* SKIP \b .* )? \z }xaai;
my $VERSION_LINE = qr/\ATAP\s+version\s+([0-9]+)\s*\z/aai;
my $BAIL_OUT     = qr/\A\s*Bail[ ]out!/aa;
my $BLOCK_START  = qr/\A(\s+)(---.*)\z/aa;
my $BLOCK_END    = qr/\A[.]{3}\s*\z/aa;
my $PRAGMA       = qr{ \A pragma \s+ ( [-+]\w+ \s* (?: , \s* [-+]\w+ \s* )* ) \z }xaa;
my $ANY_LINE     = qr/\A/;

# The grammars that a version line may name, and the pragmas that change a verdict.
my %GRAMMAR = ( 13 => 13, 14 => 13 );
my %SWITCH  = map { $_ => 1 } qw(strict ignore_exit);

# The YAML reader of TAP::Parser asks for lines until its document ends.
# This value ends a document that asks for more lines than its block holds.
my $PAST_THE_BLOCK = [];

# A comment changes nothing, and its row keeps it apart from the lines of no kind.
my $NOTHING = sub (@) { return };

# TAP::Parser fails a test beyond a leading plan, a number other than the count, and a failure that nothing excuses.
sub _test ( $work, $not, $number, $todo ) {
    my $count  = ++$work->{seen};
    my $listed = defined $number          && delete $work->{todo}{ 0 + $number };
    my $beyond = defined $work->{planned} && $count > $work->{planned};
    my $astray = defined $number          && $number != $count;
    my $broken = $not                     && !$todo && !$listed;
    $work->{phase} = 'failed' if $beyond || $astray || $broken;
    return;
}

sub _plan ( $work, $count, $list ) {
    my %todo = map { $_ => 1 } split q{ }, $list;
    $work->{planned} = 0 + $count;
    $work->{todo}    = \%todo;
    return;
}

sub _version ( $work, $number ) {
    if ( $GRAMMAR{$number} ) {
        $work->{grammar} = $GRAMMAR{$number};
    }
    else {
        $work->{phase} = 'failed';
    }
    return;
}

sub _bail_out ( $work, @parts ) {
    $work->{bailed} = 1;
    return;
}

sub _open_block ( $work, $pad, $marker ) {
    $work->{block} = { width => length $pad, lines => [$marker] };
    return;
}

sub _pragma ( $work, $list ) {
    for my $switch ( $list =~ /([-+]\w+)/gaa ) {
        my $name = substr $switch, 1;
        $work->{$name} = $switch =~ /\A[+]/ ? 1 : 0 if $SWITCH{$name};
    }
    return;
}

sub _unknown ( $work, @parts ) {
    $work->{phase} = 'failed' if $work->{strict};
    return;
}

# The grammar of the reader: one row for each kind of line, in the order of TAP::Parser::Grammar.
# A line has the kind of the first row whose pattern matches it, and the last row matches every line.
# A row holds the pattern under version 12, the pattern under versions 13 and 14, the next phases, and the action.
# The next phases stand in the order of @PHASES, and a line that TAP::Parser refuses in a phase leads to failed.
my @KINDS = (
    [ $TEST,         $TEST,         [qw(unplanned unplanned planned unplanned failed failed)], \&_test ],
    [ $COMMENT,      $COMMENT,      \@PHASES,                                                  $NOTHING ],
    [ $PLAN_12,      $PLAN_13,      [qw(planned planned failed closed failed failed)],         \&_plan ],
    [ $VERSION_LINE, $VERSION_LINE, [qw(versioned failed failed failed failed failed)],        \&_version ],
    [ $BAIL_OUT,     $BAIL_OUT,     \@PHASES,                                                  \&_bail_out ],
    [ undef,         $BLOCK_START,  \@PHASES,                                                  \&_open_block ],
    [ undef,         $PRAGMA,       \@PHASES,                                                  \&_pragma ],
    [ $ANY_LINE,     $ANY_LINE,     \@PHASES,                                                  \&_unknown ],
);

my %ROWS = ( 12 => [], 13 => [] );
for my $kind (@KINDS) {
    my ( $old, $new, $after, $act ) = $kind->@*;
    my %pattern = ( 12 => $old, 13 => $new );
    my %follows;
    @follows{@PHASES} = $after->@*;
    for my $grammar ( grep { $pattern{$_} } sort keys %pattern ) {
        push $ROWS{$grammar}->@*, { pattern => $pattern{$grammar}, follows => \%follows, act => $act };
    }
}

# The reader of TAP::Parser decides what a YAML document is, and it comes with Perl.
sub _is_document (@lines) {
    require TAP::Parser::YAMLish::Reader;
    local $@ = q{};
    local $SIG{__WARN__} = sub { };
    my $next = sub { return @lines ? shift @lines : die $PAST_THE_BLOCK };    ## no critic (ErrorHandling::RequireCarping)
    return eval { TAP::Parser::YAMLish::Reader->new->read($next); 1 } ? 1 : 0;
}

# A YAML block holds every line up to three dots at its own indentation, and TAP::Parser reads none of them as TAP.
sub _continue_block ( $work, $line ) {
    my $block = $work->{block};
    $work->{block} = undef;
    my ($pad) = $line =~ /\A(\s*)/aa;
    if ( length $pad < $block->{width} ) {
        $work->{phase} = 'failed';
    }
    elsif ( ( push $block->{lines}->@*, substr $line, $block->{width} ) && $block->{lines}[-1] !~ $BLOCK_END ) {
        $work->{block} = $block;
    }
    elsif ( !_is_document( $block->{lines}->@* ) ) {
        $work->{phase} = 'failed';
    }
    return;
}

sub _read ( $work, $line ) {
    return _continue_block( $work, $line ) if $work->{block};
    for my $kind ( $ROWS{ $work->{grammar} }->@* ) {
        my @parts = $line =~ $kind->{pattern} or next;
        $work->{phase} = $kind->{follows}{ $work->{phase} };
        return $kind->{act}->( $work, @parts );
    }
    return;
}

# TAP::Parser drops the empty lines at the end of a stream, so an empty line counts when a later line follows it.
sub _take ( $work, $line ) {
    if ( length $line ) {
        _read( $work, q{} ) if $work->{blank};
        $work->{blank} = 0;
        _read( $work, $line );
    }
    else {
        $work->{blank} = 1;
    }
    return;
}

# A state of its own for the lines of one call, so the state of the caller stays as it was.
sub _private ($state) {
    my $block = $state->{block};
    return {
        $state->%*,
        todo  => { $state->{todo}->%* },
        block => $block ? { width => $block->{width}, lines => [ $block->{lines}->@* ] } : undef,
    };
}

signature_for start => ( positional => [], returns => $STATE );

sub start () {
    return {
        grammar     => 12,
        phase       => 'start',
        planned     => undef,
        seen        => 0,
        todo        => {},
        strict      => 0,
        ignore_exit => 0,
        bailed      => 0,
        blank       => 0,
        block       => undef,
        rest        => q{},
    };
}

signature_for feed => ( positional => [ $STATE, Str ], returns => $STATE );

sub feed ( $state, $piece ) {
    my $text = $state->{rest} . $piece;
    my $cut  = 1 + rindex $text, "\n";
    my $work = _private($state);
    _take( $work, $_ ) for substr( $text, 0, $cut ) =~ /([^\n]*)\n/g;
    $work->{rest} = substr $text, $cut;
    return $work;
}

signature_for finish => ( positional => [$STATE], returns => $STATE );

sub finish ($state) {
    my $work = _private($state);
    _take( $work, $work->{rest} );
    $work->{rest}  = q{};
    $work->{blank} = 0;
    $work->{phase} = 'failed' if $work->{block};
    return $work;
}

signature_for failed_already => ( positional => [$STATE], returns => Bool );

sub failed_already ($state) {
    return $state->{phase} eq 'failed' || $state->{bailed} ? 1 : 0;
}

signature_for passed => ( positional => [ $STATE, Int ], returns => Bool );

sub passed ( $state, $status ) {
    my $end = finish($state);
    return 0 if failed_already($end);
    return 0 if $status != 0 && !$end->{ignore_exit};
    return defined $end->{planned} && $end->{seen} == $end->{planned} ? 1 : 0;
}

1;

__END__

=head1 NAME

Test::Mutation::Tap - give the verdict of prove on a TAP stream that arrives in pieces

=head1 SYNOPSIS

    my $state = Test::Mutation::Tap::start();
    $state = Test::Mutation::Tap::feed( $state, $_ ) for "1..2\nok 1\nno", "t ok 2\n";
    my $stop_now = Test::Mutation::Tap::failed_already($state);
    my $end      = Test::Mutation::Tap::finish($state);
    my $passed   = Test::Mutation::Tap::passed( $state, $? );

=head1 DESCRIPTION

The functions fold a TAP stream into a small state, and the state gives the verdict that C<TAP::Parser> gives.
A stream passes when C<TAP::Parser> reports no problem and no bail out, and every other stream fails.
The pieces of a stream may end anywhere, and every way to cut one stream gives the same verdict.

The reader holds one table of the kinds of line.
The kinds are a test, a comment, a plan, a version, a bail out, the start of a YAML block, a pragma, and a line of no kind.
Each row has the pattern of C<TAP::Parser::Grammar> under version 12 and under versions 13 and 14.
A version line, a plan, and a test move the stream from one phase to the next.
A line that C<TAP::Parser> refuses in a phase fails the stream.
A failure, a refused line, and a bail out are final, so the same state answers during the run and after it.

Indented lines belong to subtests and change nothing, apart from a bail out and the lines of a YAML block.
The reader hands a YAML block of version 13 to C<TAP::Parser::YAMLish::Reader>, which comes with Perl.
It holds the lines of such a block and the last line without a newline in memory until each one ends.

The reader takes bytes, and it reads a stream as C<TAP::Parser> reads a text.
C<TAP::Parser> joins a line that holds C<not> alone to the next line on VMS, and the reader joins no lines.

=head1 FUNCTIONS

=head2 start

Returns the state before any piece.

A state has the keys C<grammar>, C<phase>, C<planned>, C<seen>, C<todo>, C<strict>, C<ignore_exit>, C<bailed>, C<blank>, C<block>, and C<rest>.
C<phase> is C<failed> once a test failed or C<TAP::Parser> would report an error.
C<bailed> is true after a bail out.

=head2 feed

Returns the state after one more piece of the stream.
A line counts when its newline arrives.

=head2 finish

Returns the state of a stream that ends here.
The last line counts without a newline, and a YAML block that no line ended fails the stream.

=head2 failed_already

True when a failure or a bail out makes the final verdict a failure whatever follows.

=head2 passed

True when the stream that ends here passes and the process ended well.
The second argument is the wait status of the process.
A stream with a plan passes when no line failed it and the number of tests equals the plan.
A process ended well with a wait status of zero, and with every status after the pragma C<ignore_exit>.

=cut
