package Test::Mutation::Once;
use v5.36;
use Types::Standard qw(CodeRef Dict);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

signature_for coalesce => (
    positional => [ CodeRef, CodeRef, CodeRef ],
    returns    => Dict [ next => CodeRef, done => CodeRef ],
);

sub coalesce ( $next, $done, $key ) {
    my ( %waiting, %completed, @follow );
    my $deliver = sub ( $task, $result ) {
        my $later = $done->( $task, $result );
        push @follow, $later if $later;
        return;
    };
    return {
        next => sub {
            while ( my $task = shift(@follow) || $next->() ) {
                my $id = $key->($task);
                return $task unless defined $id;
                if ( exists $completed{$id} ) {
                    $deliver->( $task, $completed{$id} );
                    next;
                }
                if ( exists $waiting{$id} ) {
                    push $waiting{$id}->@*, $task;
                    next;
                }
                $waiting{$id} = [];
                return $task;
            }
            return;
        },
        done => sub ( $task, $result ) {
            my $id    = $key->($task);
            my @tasks = ($task);
            if ( defined $id ) {
                $completed{$id} = $result;
                push @tasks, ( delete $waiting{$id} )->@*;
            }
            $deliver->( $_, $result ) for @tasks;
            return;
        },
    };
}

1;

__END__

=head1 NAME

Test::Mutation::Once - share a completed process result with tasks that request the same work

=head1 FUNCTIONS

=head2 coalesce

Wraps the pending and completed callbacks of a process pool.
Each defined key starts one process during the run.
All waiting and later tasks receive its result with their original task payload.
A task without a key runs independently.

=cut
