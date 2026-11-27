use v5.36;
use Test2::V0;
use Storable    ();
use TAP::Parser ();
use Test::Mutation::Tap;

# The reader takes a stream in pieces, and it gives the verdict of TAP::Parser whatever the pieces are.
# Each case states the verdict by hand, and the parser of prove confirms it where the parser answers.

sub fed (@pieces) {
    my $state = Test::Mutation::Tap::start();
    $state = Test::Mutation::Tap::feed( $state, $_ ) for @pieces;
    return $state;
}

# The ways to cut a stream: in one piece, one line in each piece, one byte in each piece, and every cut in two.
sub cuttings ($text) {
    my @whole = length $text ? ($text) : ();
    return (
        [ 'in one piece', @whole ],
        [ 'line by line', $text =~ /([^\n]*\n|[^\n]+\z)/g ],
        [ 'byte by byte', split //, $text ],
        map { [ "cut after $_ bytes", substr( $text, 0, $_ ), substr( $text, $_ ) ] } 1 .. length($text) - 1,
    );
}

# What prove says about the stream of a process that exits with status 0, or nothing where its parser gives up.
sub parser_passes ($text) {
    return if $text !~ /\n/;
    local $SIG{__WARN__} = sub { };
    my $bailed = 0;
    my $passes = eval {
        my $parser = TAP::Parser->new( { tap => $text } );
        while ( my $result = $parser->next ) {
            $bailed = 1 if $result->is_bailout;
        }
        $parser->has_problems ? 0 : 1;
    };
    return defined $passes ? $passes && !$bailed ? 1 : 0 : undef;
}

my $V13      = "TAP version 13\n";
my $STRICT   = "TAP version 13\npragma +strict\n";
my $EXIT_ONE = 1 << 8;
my $SIGTERM  = 15;

# The name, the stream, the wait status of the process, whether the test passed, and whether its stream had failed.
my @cases = (
    [ 'all tests pass',                  "1..2\nok 1\nok 2 - named\n",                                0,         1, 0 ],
    [ 'a plan at the end',               "ok 1\nok 2\n1..2\n",                                        0,         1, 0 ],
    [ 'a failure',                       "1..2\nok 1\nnot ok 2 - broken\n",                           0,         0, 1 ],
    [ 'a failure before the plan',       "not ok 1\n1..1\n",                                          0,         0, 1 ],
    [ 'a missing plan',                  "ok 1\nok 2\n",                                              0,         0, 0 ],
    [ 'fewer tests than planned',        "1..3\nok 1\n",                                              0,         0, 0 ],
    [ 'fewer tests than a late plan',    "ok 1\n1..3\n",                                              0,         0, 0 ],
    [ 'a test beyond the plan',          "1..1\nok 1\nok 2\n",                                        0,         0, 1 ],
    [ 'more tests than a late plan',     "ok 1\nok 2\n1..1\n",                                        0,         0, 0 ],
    [ 'a test after a plan of none',     "1..0\nok 1\n",                                              0,         0, 1 ],
    [ 'a nonzero exit status',           "1..1\nok 1\n",                                              $EXIT_ONE, 0, 0 ],
    [ 'the end by a signal',             "1..1\nok 1\n",                                              $SIGTERM,  0, 0 ],
    [ 'no output',                       q{},                                                         0,         0, 0 ],
    [ 'a line of no kind',               "1..1\nok 1\nokay then\n",                                   0,         1, 0 ],
    [ 'a comment',                       "# not ok\n1..1\nok 1\n",                                    0,         1, 0 ],
    [ 'a failure inside a subtest only', "    not ok 1 - inner\n    1..1\nok 1 - outer\n1..1\n",      0,         1, 0 ],
    [ 'a failed subtest',                "    not ok 1 - inner\n    1..1\nnot ok 1 - outer\n1..1\n",  0,         0, 1 ],
    [ 'a last line without a newline',   "1..2\nok 1\nok 2",                                          0,         1, 0 ],
    [ 'a late plan without a newline',   "ok 1\n1..1",                                                0,         1, 0 ],
    [ 'a failure without a newline',     "1..1\nnot ok 1",                                            0,         0, 1 ],
    [ 'lines that end with CR and LF',   "1..2\r\nok 1\r\nnot ok 2 # TODO later\r\n",                 0,         1, 0 ],
    [ 'a second plan',                   "1..2\nok 1\nok 2\n1..2\n",                                  0,         0, 1 ],
    [ 'two plans before the tests',      "1..1\n1..1\nok 1\n",                                        0,         0, 1 ],
    [ 'a plan in the middle',            "ok 1\n1..2\nok 2\n",                                        0,         0, 1 ],
    [ 'a second plan after a late plan', "ok 1\n1..1\n1..1\n",                                        0,         0, 1 ],
    [ 'a plan with text after it',       "1..2 and more\nok 1\nok 2\n",                               0,         0, 0 ],
    [ 'a plan with spaces after it',     "1..2  \nok 1\nok 2\n",                                      0,         1, 0 ],
    [ 'a plan with a padded count',      "1..02\nok 1\nok 2\n",                                       0,         1, 0 ],
    [ 'a plan of none',                  "1..0\n",                                                    0,         1, 0 ],
    [ 'a plan of none with a reason',    "1..0 # SKIP not supported\n",                               0,         1, 0 ],
    [ 'a plan of none with any text',    "1..0 and more\n",                                           0,         1, 0 ],
    [ 'a plan of none in two digits',    "1..00\n",                                                   0,         1, 0 ],
    [ 'a plan of ten',                   "1..10\n" . join( q{}, map { "ok $_\n" } 1 .. 10 ),          0,         1, 0 ],
    [ 'a plan that skips with tests',    "1..1 # SKIP later\nok 1\n",                                 0,         0, 0 ],
    [ 'a plan beyond every integer',     '1..' . '9' x 30 . "\nok 1\n",                               0,         0, 0 ],
    [ 'a plan beyond every number',      '1..' . '9' x 400 . "\nok 1\n",                              0,         0, 0 ],
    [ 'a plan after a byte that is no space', "1..1\xA0\nok 1\n",                                     0,         0, 0 ],
    [ 'a list of unfinished tests',           "1..2 todo 2\nok 1\nnot ok 2\n",                        0,         1, 0 ],
    [ 'a list of two unfinished tests',       "1..2 todo 1 2 and more\nnot ok 1\nnot ok 2\n",         0,         1, 0 ],
    [ 'a list right after the count',         "1..2todo 2\nok 1\nnot ok 2\n",                         0,         1, 0 ],
    [ 'a list that names another test',       "1..2 todo 1\nok 1\nnot ok 2\n",                        0,         0, 1 ],
    [ 'a list with a padded number',          "1..2 todo 02\nok 1\nnot ok 2\n",                       0,         0, 1 ],
    [ 'a list and a test with no number',     "1..2 todo 2\nok\nnot ok\n",                            0,         0, 1 ],
    [ 'a list without a number',              "1..2 todo\nok 1\nok 2\n",                              0,         0, 0 ],
    [ 'a list on a late plan',                "ok 1\nnot ok 2\n1..2 todo 2\n",                        0,         0, 1 ],
    [ 'numbers with a gap',                   "1..2\nok 1\nok 3\n",                                   0,         0, 1 ],
    [ 'numbers in another order',             "1..2\nok 2\nok 1\n",                                   0,         0, 1 ],
    [ 'a number twice',                       "1..2\nok 1\nok 1\n",                                   0,         0, 1 ],
    [ 'numbers from zero',                    "1..1\nok 0\n",                                         0,         0, 1 ],
    [ 'padded numbers',                       "1..2\nok 01\nok 002\n",                                0,         1, 0 ],
    [ 'tests without numbers',                "1..2\nok\nok\n",                                       0,         1, 0 ],
    [ 'a number after a test without',        "1..2\nok\nok 2\n",                                     0,         1, 0 ],
    [ 'a wrong number after one without',     "1..2\nok\nok 1\n",                                     0,         0, 1 ],
    [ 'a number beyond every integer',        "1..1\nok " . '9' x 30 . "\n",                          0,         0, 1 ],
    [ 'a number right after the word',        "1..1\nok1\n",                                          0,         0, 0 ],
    [ 'a tab after the word',                 "1..1\nok\t1\n",                                        0,         1, 0 ],
    [ 'a name right after the word',          "1..1\nok-1\n",                                         0,         1, 0 ],
    [ 'a byte above ASCII after the word',    "1..1\nok\xE9\n",                                       0,         1, 0 ],
    [ 'the word in upper case',               "1..1\nOK 1\n",                                         0,         0, 0 ],
    [ 'two spaces inside a failure',          "1..1\nnot  ok 1\n",                                    0,         0, 0 ],
    [ 'an unfinished test',                   "1..1\nnot ok 1 - later # TODO unfinished\n",           0,         1, 0 ],
    [ 'an unfinished test in lower case',     "1..1\nnot ok 1 # todo unfinished\n",                   0,         1, 0 ],
    [ 'an unfinished test, no space',         "1..1\nnot ok 1 #TODO\n",                               0,         1, 0 ],
    [ 'an unfinished test, no number',        "1..1\nnot ok # TODO\n",                                0,         1, 0 ],
    [ 'an unfinished test that passes',       "1..1\nok 1 # TODO done\n",                             0,         1, 0 ],
    [ 'a longer word than TODO',              "1..1\nnot ok 1 # TODONE\n",                            0,         0, 1 ],
    [ 'TODO without a hash',                  "1..1\nnot ok 1 - TODO later\n",                        0,         0, 1 ],
    [ 'an escaped hash before TODO',          "1..1\nnot ok 1 - name \\# TODO\n",                     0,         0, 1 ],
    [ 'an escaped backslash and a hash',      "1..1\nnot ok 1 - name \\\\# TODO\n",                   0,         1, 0 ],
    [ 'a hash after an escaped hash',         "1..1\nnot ok 1 - a \\# b # TODO c\n",                  0,         1, 0 ],
    [ 'TODO after another hash',              "1..1\nnot ok 1 - issue # 12 # TODO later\n",           0,         0, 1 ],
    [ 'a skipped test',                       "1..1\nok 1 # SKIP no network\n",                       0,         1, 0 ],
    [ 'a skipped test that fails',            "1..1\nnot ok 1 # SKIP no network\n",                   0,         0, 1 ],
    [ 'SKIP and then TODO',                   "1..1\nnot ok 1 # SKIP a # TODO b\n",                   0,         0, 1 ],
    [ 'a bail out',                           "1..3\nok 1\nBail out! disk full\n",                    0,         0, 1 ],
    [ 'a bail out alone',                     "Bail out!\n",                                          0,         0, 1 ],
    [ 'a bail out after the last test',       "1..1\nok 1\nBail out!\n",                              0,         0, 1 ],
    [ 'a bail out inside a subtest',          "1..1\n    Bail out! inside\nok 1\n",                   0,         0, 1 ],
    [ 'a bail out in lower case',             "1..1\nok 1\nbail out! no\n",                           0,         1, 0 ],
    [ 'version 13',                           "${V13}1..1\nok 1\n",                                   0,         1, 0 ],
    [ 'version 14',                           "TAP version 14\n1..1\nok 1\n",                         0,         1, 0 ],
    [ 'a version in another case',            "tap VERSION 13  \n1..1\nok 1\n",                       0,         1, 0 ],
    [ 'a version after a comment',            "# early\nnot TAP\n${V13}1..1\nok 1\n",                 0,         1, 0 ],
    [ 'version 12',                           "TAP version 12\n1..1\nok 1\n",                         0,         0, 1 ],
    [ 'version 15',                           "TAP version 15\n1..1\nok 1\n",                         0,         0, 1 ],
    [ 'version 13 with a zero before it',     "TAP version 013\n1..1\nok 1\n",                        0,         0, 1 ],
    [ 'a version that is no integer',         "TAP version 13.5\n1..1\nok 1\n",                       0,         1, 0 ],
    [ 'a version after the plan',             "1..1\n${V13}ok 1\n",                                   0,         0, 1 ],
    [ 'a version after a test',               "ok 1\n${V13}1..1\n",                                   0,         0, 1 ],
    [ 'a version after a late plan',          "ok 1\n1..1\n${V13}",                                   0,         0, 1 ],
    [ 'a second version',                     "${V13}${V13}1..1\nok 1\n",                             0,         0, 1 ],
    [ 'version 13: a plan that skips',        "${V13}1..1 # skip later\nok 1\n",                      0,         1, 0 ],
    [ 'version 13: a plan of none',           "${V13}1..0 # SKIP all\n",                              0,         1, 0 ],
    [ 'version 13: text after no tests',      "${V13}1..0 and more\n",                                0,         0, 0 ],
    [ 'version 13: no list in a plan',        "${V13}1..2 todo 2\nok 1\nnot ok 2\n",                  0,         0, 1 ],
    [ 'version 13: a late plan',              "${V13}ok 1\n1..1\n",                                   0,         1, 0 ],
    [ 'version 13: a second plan',            "${V13}1..1\nok 1\n1..1\n",                             0,         0, 1 ],
    [ 'a pragma under version 12',            "pragma +strict\n1..1\nok 1\nno TAP\n",                 0,         1, 0 ],
    [ 'strict: a line of no kind',            "${STRICT}1..1\nok 1\nno TAP\n",                        0,         0, 1 ],
    [ 'strict: a comment',                    "${STRICT}1..1\n# fine\nok 1\n",                        0,         1, 0 ],
    [ 'strict: the lines of a subtest',       "${STRICT}    ok 1\n    1..1\nok 1\n1..1\n",            0,         0, 1 ],
    [ 'strict: a pragma without a sign',      "${STRICT}pragma strict\n1..1\nok 1\n",                 0,         0, 1 ],
    [ 'strict, and off again',                "${STRICT}pragma -strict\n1..1\nok 1\nno TAP\n",        0,         1, 0 ],
    [ 'strict off and on in one line',        "${V13}pragma -strict, +strict\n1..1\nok 1\nno TAP\n",  0,         0, 1 ],
    [ 'strict on and off in one line',        "${V13}pragma +strict , -strict\n1..1\nok 1\nno TAP\n", 0,         1, 0 ],
    [ 'strict after another pragma',          "${V13}pragma +other,+strict\n1..1\nok 1\nno TAP\n",    0,         0, 1 ],
    [ 'strict before another pragma',         "${V13}pragma +strict, -other\n1..1\nok 1\nno TAP\n",   0,         0, 1 ],
    [ 'strict: an empty line',                "${STRICT}1..1\n\nok 1\n",                              0,         0, 1 ],
    [ 'strict: empty lines at the end',       "${STRICT}1..1\nok 1\n\n\n",                            0,         1, 0 ],
    [ 'strict: an empty line before it',      "\n${STRICT}1..1\nok 1\n",                              0,         1, 0 ],
    [ 'strict: an empty line and no newline', "${STRICT}1..1\n\nok 1",                                0,         0, 1 ],
    [ 'strict: a line of a carriage return',  "${STRICT}1..1\nok 1\n\r\n",                            0,         0, 1 ],
    [ 'ignore_exit: a failing exit status',   "${V13}pragma +ignore_exit\n1..1\nok 1\n",              $EXIT_ONE, 1, 0 ],
    [ 'ignore_exit: the end by a signal',     "${V13}pragma +ignore_exit\n1..1\nok 1\n",              $SIGTERM,  1, 0 ],
    [ 'ignore_exit: a failed test',           "${V13}pragma +ignore_exit\n1..1\nnot ok 1\n",          $EXIT_ONE, 0, 1 ],
    [ 'ignore_exit, and off again',   "${V13}pragma +ignore_exit\npragma -ignore_exit\n1..1\nok 1\n", $EXIT_ONE, 0, 0 ],
    [ 'ignore_exit under version 12', "pragma +ignore_exit\n1..1\nok 1\n",                            $EXIT_ONE, 0, 0 ],
    [ 'a YAML block',                 "${V13}1..1\nok 1\n  ---\n  message: fine\n  ...\n",            0,         1, 0 ],
    [ 'a YAML block and a test after it',   "${V13}ok 1\n  ---\n  - one\n  - two\n  ...  \nok 2\n1..2\n",     0, 1, 0 ],
    [ 'two YAML blocks',                    "${V13}ok 1\n ---\n a: 1\n ...\nok 2\n ---\n b: 2\n ...\n1..2\n", 0, 1, 0 ],
    [ 'a YAML block under strict',          "${STRICT}1..1\nok 1\n  ---\n  message: fine\n  ...\n",           0, 1, 0 ],
    [ 'a bail out as text of a YAML block', "${V13}1..1\nok 1\n  ---\n  out: |\n    Bail out! no\n  ...\n",   0, 1, 0 ],
    [ 'a YAML block that no line ends',     "${V13}1..2\nok 1\n  ---\n  message: fine\nok 2\n",               0, 0, 1 ],
    [ 'a YAML block at the end',            "${V13}1..1\nok 1\n  ---\n  message: fine\n",                     0, 0, 1 ],
    [ 'a YAML block that is no document',   "${V13}1..1\nok 1\n  ---\n  no key\n  ...\n",                     0, 0, 1 ],
    [ 'a YAML block with a short line',     "${V13}1..1\nok 1\n  ---\n  a: 1\n b: 2\n  ...\n",                0, 0, 1 ],
    [ 'a YAML block with an empty line',    "${V13}1..1\nok 1\n  ---\n  a: 1\n\n  b: 2\n  ...\n",             0, 0, 1 ],
    [ 'a YAML block with a deeper end',     "${V13}1..1\nok 1\n  ---\n  a: 1\n   ...\n  ...\n",               0, 0, 1 ],
    [ 'a YAML block and no newline',        "${V13}1..1\nok 1\n  ---\n  message: fine\n  ...",                0, 1, 0 ],
    [ 'a YAML text that never ends',        "${V13}1..1\nok 1\n  --- |\n  text\n  ...\n",                     0, 0, 1 ],
    [ 'the lines of a block, version 12',   "1..1\nok 1\n  ---\n  no key\n",                                  0, 1, 0 ],
    [ 'a bail out in a block, version 12',  "1..1\nok 1\n  ---\n  out: |\n    Bail out! no\n  ...\n",         0, 0, 1 ],
);

# The parser of prove takes a text without a newline for the name of a file, and it dies on a version with a zero.
# On a YAML text at the indentation of its block it asks for lines without an end, so no test asks it.
my $endless = 'a YAML text that never ends';
is [ map { scalar parser_passes($_) } q{}, "TAP version 013\n1..1\nok 1\n" ], [ undef, undef ],
  'the parser of prove gives no verdict on two of the streams';

my $confirmed = 0;
for my $case (@cases) {
    my ( $name, $text, $status, $passed, $early ) = $case->@*;
    my $says = $name eq $endless ? undef : parser_passes($text);
    if ( $status == 0 && defined $says ) {
        is $says, $passed, "$name: the parser of prove gives the stated verdict";
        $confirmed++;
    }
    my %differs;
    for my $cutting ( cuttings($text) ) {
        my ( $how, @pieces ) = $cutting->@*;
        my $state = fed(@pieces);
        my $end   = Test::Mutation::Tap::finish($state);
        $differs{"$how: passed"}         = 1 if Test::Mutation::Tap::passed( $state, $status ) != $passed;
        $differs{"$how: failed already"} = 1 if Test::Mutation::Tap::failed_already($end) != $early;
    }
    is [ sort keys %differs ], [], "$name: passed is $passed and failed already is $early, however the stream is cut";
}
ok $confirmed >= 122, "the parser of prove confirmed $confirmed verdicts";

# prove reads a process, and after a version line of 13 or 14 it decodes each line from UTF-8 before the grammar reads it.
# A byte that starts no character becomes a replacement character, and the bytes of version 12 stay bytes.
sub process_passes ($text) {
    local $SIG{__WARN__} = sub { };
    my $script = sprintf q{binmode STDOUT; print pack 'H*', '%s';}, unpack 'H*', $text;
    my $parser = TAP::Parser->new( { exec => [ $^X, '-e', $script ] } );
    my $bailed = 0;
    while ( my $result = $parser->next ) {
        $bailed = 1 if $result->is_bailout;
    }
    return !$parser->has_problems && !$bailed ? 1 : 0;
}

my @decoded = (
    [ 'a letter after ok, version 12',                    "1..1\nok\xC3\xA9\n",                                 1, 0 ],
    [ 'a letter after ok, version 13',                    "${V13}1..1\nok\xC3\xA9\n",                           0, 0 ],
    [ 'a letter after ok, version 14',                    "TAP version 14\n1..1\nok\xC3\xA9\n",                 0, 0 ],
    [ 'a symbol after ok',                                "${V13}1..1\nok\xE2\x86\x92\n",                       1, 0 ],
    [ 'a byte of no character after ok',                  "${V13}1..1\nok\xE9\n",                               1, 0 ],
    [ 'a digit beyond ASCII for the number',              "${V13}1..1\nok \xD9\xA3\n",                          0, 1 ],
    [ 'a digit beyond ASCII after an ASCII digit',        "${V13}1..1\nok 1\xD9\xA3\n",                         1, 0 ],
    [ 'a digit beyond ASCII, version 12',                 "1..1\nok \xD9\xA3\n",                                1, 0 ],
    [ 'a space beyond ASCII after the count',             "${V13}1..1\xC2\xA0\nok 1\n",                         1, 0 ],
    [ 'a space beyond ASCII after the count, version 12', "1..1\xC2\xA0\nok 1\n",                               0, 0 ],
    [ 'a count beyond ASCII',                             "${V13}1..\xD9\xA3\n",                                1, 0 ],
    [ 'a space beyond ASCII before a bail out',           "${V13}1..1\nok 1\n\xC2\xA0Bail out!\n",              0, 1 ],
    [ 'a YAML key that starts beyond ASCII',        "${V13}1..1\nok 1\n  ---\n  \xC3\xA9t\xC3\xA9: 1\n  ...\n", 1, 0 ],
    [ 'a YAML line padded beyond ASCII',            "${V13}1..1\nok 1\n  ---\n \xC2\xA0a: 1\n  ...\n",          1, 0 ],
    [ 'TODO and a letter beyond ASCII',             "${V13}1..1\nnot ok 1 # TODO\xC3\xA9\n",                    0, 1 ],
    [ 'TODO and a letter beyond ASCII, version 12', "1..1\nnot ok 1 # TODO\xC3\xA9\n",                          1, 0 ],
    [ 'bytes of no character in a comment',         "${V13}# \xFF\xFE\n1..1\nok 1\n",                           1, 0 ],
    [ 'a line that ends inside a character',        "${V13}1..1\nok 1 - caf\xC3\n",                             1, 0 ],
    [ 'a pragma with a letter beyond ASCII',        "${V13}pragma +strict\xC3\xA9\n1..1\nok 1\nno TAP\n",       1, 0 ],
);
for my $case (@decoded) {
    my ( $name, $text, $passed, $early ) = $case->@*;
    is process_passes($text), $passed, "$name: the parser of prove on a process gives the stated verdict";
    my %differs;
    for my $cutting ( cuttings($text) ) {
        my ( $how, @pieces ) = $cutting->@*;
        my $state = fed(@pieces);
        $differs{"$how: passed"}         = 1 if Test::Mutation::Tap::passed( $state, 0 ) != $passed;
        $differs{"$how: failed already"} = 1
          if Test::Mutation::Tap::failed_already( Test::Mutation::Tap::finish($state) ) != $early;
    }
    is [ sort keys %differs ], [], "$name: passed is $passed and failed already is $early, however the stream is cut";
}

subtest 'a line counts when its newline arrives' => sub {
    my $open = fed("1..1\nnot ok 1");
    is Test::Mutation::Tap::failed_already($open), 0, 'the unfinished line fails nothing yet';
    is Test::Mutation::Tap::failed_already( Test::Mutation::Tap::feed( $open, " # TODO later\n" ) ), 0,
      'and its end may still excuse it';
    is Test::Mutation::Tap::failed_already( Test::Mutation::Tap::feed( $open, "\n" ) ), 1, 'the newline fails it';
    is Test::Mutation::Tap::failed_already( Test::Mutation::Tap::finish($open) ),       1, 'and so does the end';
    is Test::Mutation::Tap::failed_already( fed("${V13}1..1\nok 1\n  ---\n  a: 1\n") ), 0,
      'an open YAML block fails nothing yet';
    is Test::Mutation::Tap::failed_already( fed("${STRICT}1..1\nok 1\n\n") ), 0,
      'an empty line under strict fails nothing while it may be the last one';
};

subtest 'the reader names a bail out apart from a failure' => sub {
    is fed("1..1\nnot ok 1\n")->{bailed},                                     0, 'a failure is no bail out';
    is fed("1..1\nok 1\nBail out!\n")->{bailed},                              1, 'a bail out';
    is fed("1..1\nnot ok 1\nBail out!\n")->{bailed},                          1, 'a bail out after a failure';
    is fed("1..1\nok 1\n  Bail out! late\n")->{bailed},                       1, 'a bail out behind spaces';
    is Test::Mutation::Tap::finish( fed("1..1\nok 1\nBail out!") )->{bailed}, 1, 'a bail out without a newline';
};

subtest 'an early failure never becomes a pass' => sub {
    my @lines = (
        "1..3\n",      "ok 1\n", "not ok 2\n", "ok 3\n", "not ok 4 # TODO x\n",
        "Bail out!\n", "1..5\n", "ok\n",
        "TAP version 13\n",
        "pragma +strict\n",
        "  ---\n", "  ...\n", "\n", 'ok',
    );
    my ( @broken, $streams );
    for my $first ( 0 .. $#lines ) {
        for my $middle ( 0 .. $#lines ) {
            for my $third ( 0 .. $#lines ) {
                my @stream = @lines[ $first, $middle, $third ];
                my $state  = Test::Mutation::Tap::start();
                my $early  = 0;
                for my $line (@stream) {
                    $state = Test::Mutation::Tap::feed( $state, $line );
                    my $now = Test::Mutation::Tap::failed_already($state);
                    push @broken, "@stream: failed and then no more" if $early && !$now;
                    $early = $now;
                }
                push @broken, "@stream: failed and then passed" if $early && Test::Mutation::Tap::passed( $state, 0 );
                $streams++;
            }
        }
    }
    is \@broken, [],   'every stream that fails early stays failed and fails at the end';
    is $streams, 2744, 'the streams of three lines';
};

subtest 'feed and finish return a new state' => sub {
    my @pairs = (
        [ "1..2\nok 1\n",                      "not ok 2\n" ],
        [ "1..2 todo 2\nok 1\n",               "not ok 2\n" ],
        [ "${V13}1..1\nok 1\n  ---\n  a: 1\n", "  b: 2\n  ...\n" ],
        [ "${STRICT}1..1\nok 1\n\n",           "no TAP\n" ],
        [ "1..1\nnot ok 1",                    " # TODO\n" ],
        [ "1..2\nok 1\nok 2",                  "0\n" ],
    );
    for my $pair (@pairs) {
        my ( $text, $more ) = $pair->@*;
        my $before = fed($text);
        my $copy   = Storable::dclone($before);
        my $after  = Test::Mutation::Tap::feed( $before, $more );
        is $before,  $copy, 'feed leaves the earlier state as it was';
        isnt $after, $copy, 'and returns another one';
        my $end = Test::Mutation::Tap::finish($before);
        is $before,                           $copy, 'finish leaves the state as it was';
        is Test::Mutation::Tap::finish($end), $end,  'and the end of an ended stream is the same end';
        is Test::Mutation::Tap::passed( $before, 0 ), Test::Mutation::Tap::passed( $end, 0 ),
          'passed reads the stream as ended';
    }
};

subtest 'the reader warns about no stream' => sub {

    # The YAML reader of TAP::Parser calls itself for each level of a list, and Perl warns at a hundred levels.
    my $deep    = join q{}, map { q{ } x $_ . "-\n" } 1 .. 120;
    my @hostile = (
        "${V13}ok 1\n ---\n$deep" . q{ } x 121 . "- end\n ...\n1..1\n",
        "${V13}ok 1\n  ---\n  a: 1\n",
        "${V13}ok 1\n  --- |\n  text\n  ...\n",
        "${V13}ok 1\n  ---\n  \"a\n  ...\n",
        "1..1 todo 0\nok\n",
        "1..1\nok 1 \\\n",
        "\xFF\xFE\n1..1\nok 1\n",
        "${V13}1..\xD9\xA3\nok \xD9\xA3\nok 1\xD9\xA3\n",
    );
    for my $text (@hostile) {
        is warnings { Test::Mutation::Tap::passed( fed($text), 0 ) }, [], 'no warning';
    }
    is Test::Mutation::Tap::passed( fed( $hostile[0] ), 0 ), 1, 'a YAML block of 120 levels is a document';

    my $kept = eval { die "an earlier error\n" } || $@;
    Test::Mutation::Tap::feed( Test::Mutation::Tap::start(), "${V13}ok 1\n  ---\n  no key\n  ...\n" );
    is $@, $kept, 'a YAML block that is no document leaves the error of the caller as it was';
};

subtest 'arguments are checked' => sub {
    my $state = Test::Mutation::Tap::start();
    like dies { Test::Mutation::Tap::start('extra') }, qr/Wrong number of parameters/, 'start takes no argument';
    like dies { Test::Mutation::Tap::feed( { phase => 'start' }, "ok 1\n" ) }, qr/did not pass type constraint/,
      'feed needs a whole state';
    like dies { Test::Mutation::Tap::feed( $state, undef ) }, qr/did not pass type constraint/,
      'feed needs a piece of text';
    like dies { Test::Mutation::Tap::feed( $state, "\x{263A}\n" ) }, qr/did not pass type constraint/,
      'and the piece holds bytes, as a pipe delivers them';
    like dies { Test::Mutation::Tap::finish('state') }, qr/did not pass type constraint/, 'finish needs a state';
    like dies { Test::Mutation::Tap::failed_already('state') }, qr/did not pass type constraint/,
      'failed_already needs a state';
    like dies { Test::Mutation::Tap::passed( $state, 'zero' ) }, qr/did not pass type constraint/,
      'passed needs a numeric status';
    is $state,
      {
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
      },
      'the state before any line';
};

done_testing;
