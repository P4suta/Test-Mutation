use v5.36;
use Test2::V0;
use Config qw(%Config);
use Test::Mutation::Exit;

# The table is the one place that gives an outcome of the command its number.

my @rows = Test::Mutation::Exit::rows()->@*;

subtest 'the table names each outcome once, in rising order' => sub {
    is [ map { $_->code } @rows ], [ 0, 1, 2, 3, 4, 5, 6, 125, 126, 127, 129, 130, 131, 141, 143 ], 'the statuses';
    is [ map { $_->name } @rows ],
      [
        qw(success below-gate usage baseline-failed inconclusive environment internal exec-failed),
        qw(command-not-runnable command-not-found hangup interrupt quit pipe termination)
      ],
      'the names';
    my %meaning = map { $_->meaning => 1 } @rows;
    is scalar( keys %meaning ), scalar @rows, 'each status has a meaning of its own';
};

subtest 'a name gives its status' => sub {
    is [ map { Test::Mutation::Exit::of($_) } qw(success below-gate usage baseline-failed inconclusive) ],
      [ 0, 1, 2, 3, 4 ], 'the outcomes of a run and a refusal';
    is [ map { Test::Mutation::Exit::of($_) } qw(environment internal exec-failed termination) ],
      [ 5, 6, 125, 143 ], 'the failures and a signal';
    is [ map { Test::Mutation::Exit::of($_) } qw(command-not-runnable command-not-found) ], [ 126, 127 ],
      'the command of exec that exists and fails to run, and the command that exec finds nowhere';
    isa_ok dies { Test::Mutation::Exit::row('not-an-exit') }, ['Error::TypeTiny'],
      'an unknown exit name cannot produce a catalog entry';
    like dies { Test::Mutation::Exit::of('TERM') }, qr/did not pass type constraint/,
      'the outcome lookup refuses a signal name even when the catalog contains it';
    like dies { Test::Mutation::Exit::of('nonesuch') }, qr/did not pass type constraint/,
      'a name outside the table is refused';
};

subtest 'a signal gives 128 plus its number on this platform' => sub {
    my @names = split q{ }, $Config{sig_name};
    my %number;
    @number{@names} = split q{ }, $Config{sig_num};
    is Test::Mutation::Exit::signals(), [qw(HUP INT QUIT PIPE TERM)], 'the signals that end a run with a status';
    for my $signal ( Test::Mutation::Exit::signals()->@* ) {
        is Test::Mutation::Exit::of_signal($signal), 128 + $number{$signal}, "the status of $signal";
    }
    is [ map { $_->signal } grep { defined $_->signal } @rows ], Test::Mutation::Exit::signals(),
      'the rows of the signals name them';
    is [ grep { defined $_->signal } @rows[ 0 .. 9 ] ], [], 'and no other row names a signal';
    like dies { Test::Mutation::Exit::of_signal('termination') }, qr/did not pass type constraint/,
      'the signal lookup refuses the name of the corresponding outcome';
    like dies { Test::Mutation::Exit::of_signal('KILL') }, qr/did not pass type constraint/,
      'a signal without a row is refused';
};

done_testing;
