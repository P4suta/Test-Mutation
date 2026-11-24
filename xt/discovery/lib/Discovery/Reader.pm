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

# The pool feeds each line that a newline ends, and the rest when the stream ends.
sub _state ( $self, $text, $whole ) {
    my $state = Test::Mutation::Tap::start();
    my $rest  = $text;
    while ( $rest =~ s/\A([^\n]*)\n// ) {
        $state = Test::Mutation::Tap::feed( $state, $self->{rewrite} ? $self->{rewrite}->("$1") : $1 );
    }
    $state = Test::Mutation::Tap::feed( $state, $rest ) if $whole && length $rest;
    return $self->{settle} ? $self->{settle}->($state) : $state;
}

sub passes ( $self, $text, $exit, $signal ) {
    ( $exit, $signal ) = $self->{status}->( $exit, $signal ) if $self->{status};
    return !$signal && Test::Mutation::Tap::passed( $self->_state( $text, 1 ), $exit ) ? 1 : 0;
}

# True when the pool would end the test after the lines of the prefix.
sub stops ( $self, $prefix ) {
    return Test::Mutation::Tap::failed_already( $self->_state( $prefix, 0 ) ) ? 1 : 0;
}

my %STREAM_PASSES;

# prove fails a test with a problem in its stream or a failing end, and a bail out stops its whole run.
sub oracle ( $text, $exit, $signal ) {
    if ( !exists $STREAM_PASSES{$text} ) {
        my $parser = TAP::Parser->new( { tap => $text } );
        my $bailed = 0;
        while ( my $result = $parser->next ) {
            $bailed = 1 if $result->is_bailout;
        }
        $STREAM_PASSES{$text} = !$parser->has_problems && !$bailed ? 1 : 0;
    }
    return $STREAM_PASSES{$text} && $exit == 0 && !$signal ? 1 : 0;
}

1;
