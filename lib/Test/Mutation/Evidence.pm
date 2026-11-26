package Test::Mutation::Evidence;
use v5.36;
use Types::Standard       qw(Bool Dict HashRef Maybe Str);
use Type::Params          qw(signature_for);
use Test::Mutation::Types qw(Reason TaskRecord);

our $VERSION = '0.001';

signature_for target => (
    positional => [ TaskRecord, Str ],
    returns    => Dict [
        coverage    => Maybe [ Dict [ traced => Bool, hits => HashRef [Bool] ] ],
        breakable   => Maybe [ HashRef [Bool] ],
        load_failed => Bool,
        unresolved  => Bool,
        anomaly     => Maybe [ Dict [ reason => Reason, detail => Str ] ],
    ],
);

sub target ( $record, $path ) {
    return {
        coverage    => $record->{served}{$path},
        breakable   => $record->{breakable}{$path},
        load_failed => $record->{load_failed}{$path} || !$record->{compiled}{$path} ? 1 : 0,
        unresolved  => $record->{unresolved} && $record->{unresolved}{$path}        ? 1 : 0,
        anomaly     => scalar _anomaly( $record, $path ),
    };
}

sub _anomaly ( $record, $path ) {
    if ( !$record->{begun} ) {
        my $detail = $record->{ended} ? 'a process ended without a begin record' : 'the task produced no begin record';
        return { reason => 'no-record', detail => $detail };
    }
    return { reason => 'shim-error',   detail => join( "\n", $record->{errors}->@* ) } if $record->{errors}->@*;
    return { reason => 'outside-copy', detail => "$path was loaded from outside the copy" }
      if $record->{outside}{$path};
    return { reason => 'loaded-around-hook', detail => "$path was loaded without the hook" }
      if $record->{bypassed}{$path};
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Evidence - interpret the observations of a test for one target

=head1 SYNOPSIS

    my $evidence = Test::Mutation::Evidence::target($record, $path);

=head1 FUNCTIONS

=head2 target

Returns coverage, breakable lines, load state, and any observation failure for the target.
A task without a C<begin> record cannot establish a verdict.
A process may provide evidence before its C<END> block runs.

=cut
