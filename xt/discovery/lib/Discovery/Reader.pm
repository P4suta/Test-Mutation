package Discovery::Reader;
use v5.36;
use TAP::Parser ();
use Test::Mutation::Tap;

# The TAP reader of the tool, driven as the pool drives it, next to the oracle of prove.
# A saboteur is this reader with one part replaced.

sub new ( $class, %part ) {
    return bless {%part}, $class;
}

sub with ( $self, %part ) {
    return bless { $self->%*, %part }, ref $self;
}

# The pool feeds each piece that it reads from the pipe of a test, and a short stream arrives in one piece.
# `pieces` cuts a text into other pieces, and `rewrite` changes a piece before the reader takes it.
sub _state ( $self, $text ) {
    my $state  = Test::Mutation::Tap::start();
    my @pieces = $self->{pieces} ? $self->{pieces}->($text) : $text;
    for my $piece (@pieces) {
        $state = Test::Mutation::Tap::feed( $state, $self->{rewrite} ? $self->{rewrite}->("$piece") : $piece );
    }
    return $self->{settle} ? $self->{settle}->($state) : $state;
}

# The pool hands the wait status of the process to the reader.
sub passes ( $self, $text, $exit, $signal ) {
    ( $exit, $signal ) = $self->{status}->( $exit, $signal ) if $self->{status};
    return Test::Mutation::Tap::passed( $self->_state($text), $exit << 8 | $signal ) ? 1 : 0;
}

# True when the pool would end the test after the lines of the prefix.
sub stops ( $self, $prefix ) {
    return Test::Mutation::Tap::failed_already( $self->_state($prefix) ) ? 1 : 0;
}

my %STREAM;

sub _parsed ($text) {

    # The parser warns about a YAML block that the stream cuts short, and the harness reads its verdict alone.
    local $SIG{__WARN__} = sub { };
    my $parser = TAP::Parser->new( { tap => $text } );
    my $bailed = 0;
    while ( my $result = $parser->next ) {
        $bailed = 1 if $result->is_bailout;
    }
    return { passes => !$parser->has_problems && !$bailed ? 1 : 0, ignores_end => $parser->ignore_exit ? 1 : 0 };
}

# prove fails a test with a problem in its stream or a failing end, and a bail out stops its whole run.
# A stream of version 13 may ask the parser to ignore the end of its process.
sub oracle ( $text, $exit, $signal ) {
    my $stream = $STREAM{$text} ||= _parsed($text);
    return $stream->{passes} && ( $stream->{ignores_end} || ( $exit == 0 && !$signal ) ) ? 1 : 0;
}

my %PROCESS;

# prove reads the output of a process, and after a version line of 13 or 14 it decodes each line from UTF-8.
# The process prints its stream at once and exits with status 0.
sub process_oracle ($text) {
    if ( !exists $PROCESS{$text} ) {
        local $SIG{__WARN__} = sub { };
        my $script = sprintf q{binmode STDOUT; print pack 'H*', '%s';}, unpack 'H*', $text;
        my $parser = TAP::Parser->new( { exec => [ $^X, '-e', $script ] } );
        my $bailed = 0;
        while ( my $result = $parser->next ) {
            $bailed = 1 if $result->is_bailout;
        }
        $PROCESS{$text} = !$parser->has_problems && !$bailed ? 1 : 0;
    }
    return $PROCESS{$text};
}

1;
