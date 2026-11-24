package Test::Mutation::Commands;
use v5.36;
use Types::Standard qw(ArrayRef InstanceOf);
use Type::Params    qw(signature_for);
use Test::Mutation::Command;

our $VERSION = '0.001';

# Each row: the name, the words that select it, the usage line, the summary, and the least and most operands.
my @ROWS = (
    [ 'run',  ['run'],  'mutation [run] [options]',   'Measure how many mutants the tests detect (the default)', 0, 0 ],
    [ 'list', ['list'], 'mutation list [options]',    'Print the mutants without running a test',                0, 0 ],
    [ 'show', ['show'], 'mutation show ID [options]', 'Print one mutant as a unified diff',                      1, 1 ],
    [ 'exec', ['exec'], 'mutation exec ID -- COMMAND [ARGUMENT...]', 'Run a command with one mutant active', 2, undef ],
    [
        'merge', ['merge'],
        'mutation merge FILE... [options]',
        'Report one run from the mutation.json of every part of --shard',
        1, undef
    ],
    [
        'mutators', ['mutators'],
        'mutation mutators',
        'Print the name, the profile, and the description of every mutator',
        0, 0
    ],
    [ 'help',    [ '--help', '-h' ], 'mutation --help',    'Print this text',   0, 0 ],
    [ 'version', ['--version'],      'mutation --version', 'Print the version', 0, 0 ],
);

sub _row ( $name, $words, $usage, $summary, $least, $most ) {
    return Test::Mutation::Command->new(
        name    => $name,
        words   => $words,
        default => $name eq 'run' ? 1 : 0,
        usage   => $usage,
        summary => $summary,
        least   => $least,
        most    => $most,
    );
}

signature_for rows => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Command'] ] );

sub rows () {
    return [ map { _row( $_->@* ) } @ROWS ];
}

1;

__END__

=head1 NAME

Test::Mutation::Commands - the table of the commands

=head1 SYNOPSIS

    for my $command ( Test::Mutation::Commands::rows()->@* ) {
        say $command->usage;
    }

=head1 DESCRIPTION

The table states every command once, with the words that select it and the operands that its usage line declares.
The help text and the version are commands that an option selects.
The table describes the command as it stands, and a test compares it with the help text and the planner.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Command> for every command, in the order of the help text.

=cut
