use v5.36;
use Test2::V0;
use Test::Mutation::Error;
use Test::Mutation::Interrupted;

# A failure that the tool reports is a value with a kind, an identifier, and a message from the catalog.

subtest 'raise dies with the typed error of a message' => sub {
    my $error = dies { Test::Mutation::Error::raise( 'mutant-unknown', identifier => 'zzzz' ) };
    isa_ok $error, ['Test::Mutation::Error'], 'the exception';
    is [ $error->kind, $error->id, $error->message ],
      [ 'usage', 'mutant-unknown', 'no mutant has the identifier zzzz' ],
      'the kind and the identifier of the catalog, and the text with its value';
    is "$error", "no mutant has the identifier zzzz\n", 'the error reads as its message on a line';
    ok $error, 'and it is true';

    my $environment = dies { Test::Mutation::Error::raise( 'file-unreadable', path => 'a.pm', reason => 'gone' ) };
    is [ $environment->kind, $environment->id, $environment->message ],
      [ 'environment', 'file-unreadable', 'cannot read a.pm: gone' ], 'an error of the environment';
};

subtest 'raise refuses what is no error of the catalog' => sub {
    like dies { Test::Mutation::Error::raise('nonesuch') }, qr/did not pass type constraint/, 'an unknown message';
    like dies { Test::Mutation::Error::raise('inconclusive') }, qr/did not pass type constraint/,
      'the line of an outcome is no error';
    like dies { Test::Mutation::Error::raise( 'internal-error', text => 'x' ) }, qr/did not pass type constraint/,
      'and neither is an internal error';
    like dies { Test::Mutation::Error::raise('mutant-unknown') }, qr/\Athe message mutant-unknown takes the slots/,
      'a call without the slots of the text';
    like dies { Test::Mutation::Error->new( kind => 'internal', id => 'x', message => 'y' ) }, qr/kind/,
      'an error has the kind usage or environment';
};

subtest 'an interruption names its signal and its status' => sub {
    my %status = ( HUP => 129, INT => 130, QUIT => 131, PIPE => 141, TERM => 143 );
    for my $signal ( sort keys %status ) {
        my $interruption = Test::Mutation::Interrupted->new( signal => $signal );
        is $interruption->exit_status, $status{$signal},              "the status of $signal";
        is $interruption->message,     "interrupted by SIG$signal",   "the message of $signal";
        is "$interruption",            "interrupted by SIG$signal\n", "the line of $signal";
    }
    like dies { Test::Mutation::Interrupted->new( signal => 'KILL' ) }, qr/signal/,
      'a signal that the tool cannot handle is refused';
};

done_testing;
