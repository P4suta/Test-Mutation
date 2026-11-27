use v5.36;
use Test2::V0;
use File::Temp ();
use POSIX      ();
use Test::Mutation::Interrupted;
use Test::Mutation::Signals;
use Test::Mutation::Try;

# One function catches for the whole driver, so no other place can swallow an interruption.

my $interruption = Test::Mutation::Interrupted->new( signal => 'TERM' );

subtest 'attempt gives the value of the code or the error that ended it' => sub {
    is Test::Mutation::Try::attempt( sub { 7 } ),              { value => 7 },          'a value';
    is Test::Mutation::Try::attempt( sub { 0 } ),              { value => 0 },          'a false value is a value too';
    is Test::Mutation::Try::attempt( sub { [ 1, 2 ] } ),       { value => [ 1, 2 ] },   'a reference';
    is Test::Mutation::Try::attempt( sub { die "broken\n" } ), { error => "broken\n" }, 'the text of an error';
    my $object = bless {}, 'Some::Exception';
    ref_is Test::Mutation::Try::attempt( sub { die $object } )->{error}, $object, 'an exception object as it is';
    like dies {
        my $attempt = Test::Mutation::Try::attempt( sub { return } )
    }, qr/did not pass type constraint/, 'code without a value breaks the contract of the function';
};

subtest 'an interruption passes an attempt that asks for no interruption' => sub {
    ref_is dies {
        Test::Mutation::Try::attempt( sub { die $interruption } )
    }, $interruption, 'the interruption goes on to the caller';
    ref_is Test::Mutation::Try::attempt( sub { die $interruption }, 'interruption' )->{error}, $interruption,
      'an attempt that asks for it receives it';
    is Test::Mutation::Try::attempt( sub { 7 }, 'interruption' ), { value => 7 }, 'and still a value';
    is Test::Mutation::Try::attempt( sub { die "broken\n" }, 'interruption' ), { error => "broken\n" },
      'and still another error';
    like dies {
        Test::Mutation::Try::attempt( sub { 7 }, 'everything' )
    }, qr/did not pass type constraint/, 'another word is refused';
};

subtest 'with_cleanup runs the cleanup after the code, whatever ended the code' => sub {
    my @order;
    my $cleanup = sub { push @order, 'cleanup'; return };
    is Test::Mutation::Try::with_cleanup( sub { push @order, 'code'; 7 }, $cleanup ), 7, 'the value of the code';
    is \@order, [qw(code cleanup)],                                                      'the cleanup follows the code';

    @order = ();
    is dies {
        Test::Mutation::Try::with_cleanup( sub { die "broken\n" }, $cleanup )
    }, "broken\n", 'the error of the code goes on';
    is \@order, ['cleanup'], 'after the cleanup';

    @order = ();
    ref_is dies {
        Test::Mutation::Try::with_cleanup( sub { die $interruption }, $cleanup )
    }, $interruption, 'an interruption goes on';
    is \@order, ['cleanup'], 'after the cleanup too';

    is dies {
        Test::Mutation::Try::with_cleanup( sub { die "first\n" }, sub { die "second\n" } )
    }, "second\n", 'a cleanup that dies ends the call with its own error';
};

subtest 'the cleanup ends before a signal ends the run' => sub {
    my @order;
    my $error = dies {
        Test::Mutation::Signals::watch(
            sub {
                Test::Mutation::Try::with_cleanup( sub { 7 },
                    sub { kill 'TERM', $$; push @order, 'the cleanup ended'; return } );
                push @order, 'the code went on';
                return 1;
            }
        )
    };
    isa_ok $error, ['Test::Mutation::Interrupted'], 'the signal ends the run';
    is \@order, ['the cleanup ended'], 'when the cleanup has ended, and before the next step';
};

subtest 'a process that the code started runs no cleanup of its parent' => sub {
    my $marker = File::Temp->new;
    my $pid;
    my $lived = eval {
        Test::Mutation::Try::with_cleanup(
            sub {
                $pid = fork;
                die "fork: $!\n"           if !defined $pid;
                die "the child gives up\n" if !$pid;
                return 1;
            },
            sub {
                open my $out, '>>', $marker->filename or die "open: $!";
                print {$out} "$$\n" or die "print: $!";
                close $out          or die "close: $!";
                return;
            },
        );
        1;
    };
    POSIX::_exit( $lived ? 1 : 0 ) if !$pid;
    waitpid $pid, 0;
    is $?, 0, 'the error went on in the child';
    open my $in, '<', $marker->filename or die "open: $!";
    is [ readline $in ], ["$$\n"], 'and the owner alone ran the cleanup';
};

done_testing;
