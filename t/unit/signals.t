use v5.36;
use Test2::V0;
use IO::Select  ();
use POSIX       ();
use Time::HiRes ();
use Test::Mutation::Signals;
use Test::Mutation::Try;

# The signals that ask a program to end are handled for the whole run of a command.
# A signal is noted when it arrives, and it ends the work at the next point that the code offers.
# The two decisions are functions of the state, and the other tests send real signals to this process.

sub state_with (%fact) {
    return { owner => 100, signal => undef, raised => 0, deferred => 0, %fact };
}

# What ends a piece of code under a watch: the name of the signal, the text of an error, or nothing.
sub ended ($code) {
    my $attempt = Test::Mutation::Try::attempt( sub { $code->(); 1 }, 'interruption' );
    return 'nothing' if exists $attempt->{value};
    my $error = $attempt->{error};
    return ref $error ? $error->signal : $error;
}

subtest 'a signal is noted by the owner and ends every other process' => sub {
    is Test::Mutation::Signals::decide( state_with(), 100 ), 'record', 'the owner of the watch notes the signal';
    is Test::Mutation::Signals::decide( state_with(), 101 ), 'default',
      'a process that the owner started acts as a program without the watch';
    is Test::Mutation::Signals::decide( state_with( raised => 1, signal => 'TERM' ), 101 ), 'default',
      'whatever the state that it copied';
    like dies { Test::Mutation::Signals::decide( { owner => 100 }, 100 ) }, qr/did not pass type constraint/,
      'a state without its facts is refused';
};

subtest 'a noted signal is due once, outside a deferral' => sub {
    is Test::Mutation::Signals::due( state_with() ), 0, 'no signal, nothing to end';
    is Test::Mutation::Signals::due( state_with( signal => 'TERM' ) ), 1, 'a signal that waits ends the work';
    is Test::Mutation::Signals::due( state_with( signal => 'TERM', raised => 1 ) ), 0,
      'a signal that ended the work ends nothing again';
    is Test::Mutation::Signals::due( state_with( signal => 'TERM', deferred => 1 ) ), 0,
      'a deferral holds the signal back';
    is Test::Mutation::Signals::due( state_with( raised => 1, deferred => 1 ) ), 0, 'no signal, whatever the rest';
    like dies { Test::Mutation::Signals::due( { owner => 100 } ) }, qr/did not pass type constraint/,
      'a state without its facts is refused';
};

subtest 'a watch gives the value of its code and returns the handlers' => sub {
    my $before = $SIG{TERM};
    my $inside;
    is Test::Mutation::Signals::watch( sub { $inside = $SIG{TERM}; 7 } ), 7,       'the value of the code';
    is ref $inside,                                                       'CODE',  'the code runs under a handler';
    is $SIG{TERM},                                                        $before, 'which leaves with the watch';
    is ended(
        sub {
            Test::Mutation::Signals::watch( sub { die "broken\n" } );
        }
      ),
      "broken\n",
      'an error of the code goes on';
    is $SIG{TERM}, $before, 'and the handler leaves all the same';
};

subtest 'each signal ends the watched code at its next check, under its name' => sub {
    for my $signal (qw(HUP INT QUIT PIPE TERM)) {
        my @reached;
        is ended(
            sub {
                Test::Mutation::Signals::watch(
                    sub {
                        Test::Mutation::Signals::check();
                        push @reached, 'no signal';
                        kill $signal, $$;
                        push @reached, 'the signal is noted';
                        Test::Mutation::Signals::check();
                        push @reached, 'the check let the code go on';
                        return 1;
                    }
                );
            }
          ),
          $signal, "SIG$signal ends the code";
        is \@reached, [ 'no signal', 'the signal is noted' ], "at the check that follows SIG$signal";
    }
    is ended( sub { Test::Mutation::Signals::check(); return } ), 'nothing', 'a check without a watch does nothing';
};

subtest 'a signal under a watch writes a byte to the handle of the code that waits' => sub {
    pipe my $read, my $write or die "pipe: $!";
    my $waiting = IO::Select->new($read);
    my $bytes   = sub {
        return if !$waiting->can_read(1);
        my $count = sysread $read, my $chunk, 64;
        return $chunk;
    };
    is ended(
        sub {
            Test::Mutation::Signals::watch(
                sub {
                    Test::Mutation::Signals::waking( $write,
                        sub { kill 'TERM', $$; Test::Mutation::Signals::check() } );
                }
            );
        }
      ),
      'TERM', 'the signal ends the code as before';
    is $bytes->(), q{.}, 'and the handle holds one byte';

    is Test::Mutation::Signals::watch(
        sub {
            Test::Mutation::Signals::waking( $write, sub { 7 } );
        }
      ),
      7,
      'the value of the code';
    is ended(
        sub {
            Test::Mutation::Signals::watch(
                sub {
                    Test::Mutation::Signals::waking( $write, sub { 1 } );
                    kill 'TERM', $$;
                    syswrite $write, 'x' or die "write: $!";
                    Test::Mutation::Signals::check();
                }
            );
        }
      ),
      'TERM', 'a signal after the waiting code';
    is $bytes->(), 'x', 'leaves the handle alone';
    like dies {
        Test::Mutation::Signals::waking( 'no handle', sub { 1 } )
    }, qr/did not pass type constraint/, 'a value that is no handle is refused';
};

subtest 'the first signal ends the work once' => sub {
    my @reached;
    is Test::Mutation::Signals::watch(
        sub {
            push @reached, ended( sub { kill 'TERM', $$; Test::Mutation::Signals::check(); return } );
            push @reached, ended( sub { kill 'INT',  $$; Test::Mutation::Signals::check(); return } );
            push @reached, ended( sub { Test::Mutation::Signals::check(); return } );
            return 7;
        }
      ),
      7, 'the code after the first signal runs to its end';
    is \@reached, [ 'TERM', 'nothing', 'nothing' ], 'and a later signal ends nothing';

    is ended(
        sub {
            Test::Mutation::Signals::watch( sub { kill 'HUP', $$; Test::Mutation::Signals::check(); 1 } );
        }
      ),
      'HUP', 'the next watch starts anew';
};

subtest 'the first of two signals gives the name' => sub {
    is ended(
        sub {
            Test::Mutation::Signals::watch(
                sub { kill 'QUIT', $$; kill 'TERM', $$; Test::Mutation::Signals::check(); return 1 } );
        }
      ),
      'QUIT', 'the signal that arrived first';
};

subtest 'a deferral holds a signal back until its code has ended' => sub {
    my @reached;
    is ended(
        sub {
            Test::Mutation::Signals::watch(
                sub {
                    my $value = Test::Mutation::Signals::deferred(
                        sub {
                            kill 'TERM', $$;
                            Test::Mutation::Signals::check();
                            push @reached, 'the deferred code ended';
                            return 7;
                        }
                    );
                    push @reached, "the value $value";
                    return 1;
                }
            );
        }
      ),
      'TERM', 'the signal ends the work';
    is \@reached, ['the deferred code ended'], 'after the deferred code, and before the next step';

    @reached = ();
    is ended(
        sub {
            Test::Mutation::Signals::watch(
                sub {
                    Test::Mutation::Signals::deferred(
                        sub {
                            Test::Mutation::Signals::deferred( sub { kill 'INT', $$; return 1 } );
                            Test::Mutation::Signals::check();
                            push @reached, 'the outer code went on';
                            return 1;
                        }
                    );
                    return 1;
                }
            );
        }
      ),
      'INT', 'a signal inside two deferrals ends the work';
    is \@reached, ['the outer code went on'], 'after the outer one';

    is Test::Mutation::Signals::watch(
        sub {
            Test::Mutation::Signals::deferred( sub { 7 } );
        }
      ),
      7, 'a deferral without a signal gives the value of its code';
    is Test::Mutation::Signals::deferred( sub { 7 } ), 7, 'and so does a deferral without a watch';
};

subtest 'a signal that waits survives an error of the deferred code' => sub {
    my @reached;
    is ended(
        sub {
            Test::Mutation::Signals::watch(
                sub {
                    push @reached, ended(
                        sub {
                            Test::Mutation::Signals::deferred( sub { kill 'TERM', $$; die "broken\n" } );
                        }
                    );
                    Test::Mutation::Signals::check();
                    push @reached, 'the check let the code go on';
                    return 1;
                }
            );
        }
      ),
      'TERM', 'the next check raises it';
    is \@reached, ["broken\n"], 'after the error went on';
};

subtest 'a watch inside a watch leaves the signals to the outer one' => sub {
    my @reached;
    my $signalled = sub { kill 'TERM', $$; Test::Mutation::Signals::check(); return 1 };
    is ended(
        sub {
            Test::Mutation::Signals::watch(
                sub {
                    my $handler = $SIG{TERM};
                    is Test::Mutation::Signals::watch( sub { 7 } ), 7, 'the inner watch gives the value of its code';
                    ref_is $SIG{TERM}, $handler, 'and leaves the handler of the outer one';
                    push @reached, ended( sub { Test::Mutation::Signals::watch($signalled) } );
                    push @reached, ended( sub { Test::Mutation::Signals::watch($signalled) } );
                    return 1;
                }
            );
        }
      ),
      'nothing', 'the outer watch ends with its code';
    is \@reached, [ 'TERM', 'nothing' ], 'and the first signal ends the work once across the inner watches';
};

subtest 'a process that the owner started ends as a program without the watch' => sub {
    my $pid = Test::Mutation::Signals::watch(
        sub {
            my $child = fork;
            die "fork: $!" if !defined $child;
            return $child  if $child;
            my $lived = eval { kill 'TERM', $$; Test::Mutation::Signals::check(); Time::HiRes::sleep(5); 1 };
            POSIX::_exit( $lived ? 3 : 4 );
        }
    );
    waitpid $pid, 0;
    is [ $? & 127, $? >> 8 ], [ POSIX::SIGTERM(), 0 ], 'the signal ends the child, and no exception runs in it';
};

done_testing;
