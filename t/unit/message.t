use v5.36;
use Test2::V0;
use Test::Mutation::Exit;
use Test::Mutation::Message;

# The catalog is the one place that holds the words of a failure.

my @rows = Test::Mutation::Message::rows()->@*;
my %exit = map { $_->name => 1 } Test::Mutation::Exit::rows()->@*;

subtest 'every row names a message, its kind, its text, and its description' => sub {
    my %seen;
    for my $row (@rows) {
        my $id = $row->id;
        like $id, qr/\A[a-z]+(?:-[a-z]+)*\z/, "$id is a name of lowercase words";
        ok !$seen{$id}++,                                      "$id stands once";
        ok $exit{ $row->kind } || $row->kind eq 'interrupted', "$id has the kind of an exit status";
        like $row->text,        qr/\A\S(?:.*\S)?\z/,      "$id has one line of text";
        like $row->description, qr/\A[[:upper:]].*[.]\z/, "$id has a sentence that describes it";
    }
    ok scalar(@rows) >= 55, 'the catalog holds the messages of the library';
};

subtest 'no text shows the code that raises it' => sub {
    my @leaking = grep { $_->text =~ / at \S+ line |\b[[:upper:]]\w*(?:::\w+)+|type constraint|[\$]\w+/ } @rows;
    is [ map { $_->id } @leaking ], [], 'no place, package, variable, or wording of the type library';
};

subtest 'the slots of a text take the values of a call' => sub {
    is Test::Mutation::Message::text_of( 'mutant-unknown', identifier => 'zzzz' ),
      'no mutant has the identifier zzzz', 'one slot';
    is Test::Mutation::Message::text_of( 'directory-closed', directory => 'a b', reason => 'Not a directory' ),
      'cannot enter a b: Not a directory', 'two slots';
    is Test::Mutation::Message::text_of('inconclusive'), 'the run states no score', 'no slot';
    is Test::Mutation::Message::text_of( 'mutant-unknown', identifier => '{identifier}{reason}' ),
      'no mutant has the identifier {identifier}{reason}', 'a value with braces stays as it is';
    is Test::Mutation::Message::text_of( 'file-uncopyable', source => 'a', target => 'b', reason => 'c' ),
      'cannot copy a to b: c', 'each slot takes its own value';
};

subtest 'a call with other slots than the text is refused' => sub {
    is dies { Test::Mutation::Message::text_of('mutant-unknown') },
      "the message mutant-unknown takes the slots identifier, and the call gives none\n", 'a missing slot';
    is dies { Test::Mutation::Message::text_of( 'inconclusive', reason => 'x' ) },
      "the message inconclusive takes the slots none, and the call gives reason\n", 'a slot that the text lacks';
    is dies { Test::Mutation::Message::text_of( 'directory-closed', reason => 'x', path => 'y' ) },
      "the message directory-closed takes the slots directory reason, and the call gives path reason\n",
      'another name for a slot';
    like dies { Test::Mutation::Message::text_of('nonesuch') }, qr/did not pass type constraint/,
      'a name outside the catalog';
    like dies { Test::Mutation::Message::text_of( 'mutant-unknown', identifier => undef ) },
      qr/did not pass type constraint/, 'a value that is no text';
};

subtest 'a line of the command starts with its name' => sub {
    is Test::Mutation::Message::line('the run states no score'), "mutation: the run states no score\n",
      'the name of the command, the text, and the end of the line';
    like dies { Test::Mutation::Message::line(undef) }, qr/did not pass type constraint/, 'a text is needed';
};

subtest 'a row answers for its identifier' => sub {
    my $row = Test::Mutation::Message::row('mutator-unknown');
    is [ $row->id, $row->kind, $row->text ], [ 'mutator-unknown', 'usage', 'unknown mutator: {names}' ],
      'the row of a usage error';
    is Test::Mutation::Message::row('file-unreadable')->kind, 'environment', 'the row of an environment error';
    is [ map { Test::Mutation::Message::row($_)->kind } qw(below-gate baseline-failed inconclusive interrupted) ],
      [qw(below-gate baseline-failed inconclusive interrupted)], 'the line of an outcome has the kind of the outcome';
    like dies { Test::Mutation::Message::row('nonesuch') }, qr/did not pass type constraint/,
      'a name outside the catalog';
};

done_testing;
