package Test::Mutation::Commands;
use v5.36;
use Types::Standard qw(ArrayRef Dict InstanceOf Maybe Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Command;
use Test::Mutation::Settings;

our $VERSION = '0.001';

my @settings = grep { $_->offers('line') } Test::Mutation::Settings::rows()->@*;
my @all      = map  { $_->name } @settings;
my @baseline = map  { $_->name } grep { $_->group =~ /\A(?:project|tests|cache)\z/ } @settings;
my %grammar  = (
    paths      => [ '[PATH[:LINES]...]',           0, undef ],
    none       => [ q{},                           0, 0 ],
    identifier => [ 'ID',                          1, 1 ],
    execute    => [ 'ID -- COMMAND [ARGUMENT...]', 2, undef ],
    reports    => [ 'FILE...',                     1, undef ],
    command    => [ '[COMMAND]',                   0, 1 ],
);
my @rows = (
    [ run      => 'paths',      \@all,      'Measure how many mutants the tests detect (the default)' ],
    [ baseline => 'none',       \@baseline, 'Run the unmodified tests and report failures' ],
    [ list     => 'paths',      \@all,      'Print the mutants without running a test' ],
    [ show     => 'identifier', \@all,      'Print one mutant as a unified diff' ],
    [ exec     => 'execute',    \@all,      'Run a command with one mutant active' ],
    [ merge    => 'reports',    \@all,      'Report one run from the mutation.json of every part of --shard' ],
    [ mutators => 'none',       ['root'],   'Print the name, the profile, and the description of every mutator' ],
    [ settings => 'none',       [],         'Print the available settings and their defaults' ],
    [ help     => 'command',    [],         'Show the usage and options of a command' ],
);

sub _row ( $name, $operands, $settings, $summary ) {
    my ( $syntax, $least, $most ) = $grammar{$operands}->@*;
    my @usage = ( 'mutation', $name eq 'run' ? '[run]' : $name );
    my ( $before, $program ) = split / -- /, $syntax;
    push @usage, $before     if defined $before;
    push @usage, '[options]' if $settings->@*;
    push @usage, '--', $program if defined $program;
    return Test::Mutation::Command->new(
        name     => $name,
        words    => [$name],
        default  => $name eq 'run' ? 1 : 0,
        usage    => join( q{ }, @usage ),
        summary  => $summary,
        least    => $least,
        most     => $most,
        operands => $operands,
        settings => $settings,
    );
}

my @commands = map { _row( $_->@* ) } @rows;
my %by_name  = map { $_->name => $_ } @commands;

signature_for rows => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Command'] ] );

sub rows () {
    return [@commands];
}

signature_for of => ( positional => [Str], returns => Maybe [ InstanceOf ['Test::Mutation::Command'] ] );

sub of ($name) {
    return $by_name{$name};
}

signature_for switches =>
  ( positional => [], returns => ArrayRef [ Dict [ words => ArrayRef [Str], answer => Str, summary => Str ] ] );

sub switches () {
    return [
        { words => [ '--help', '-h' ], answer => 'help',    summary => 'Print this text' },
        { words => ['--version'],      answer => 'version', summary => 'Print the version' },
    ];
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

The argument parser and help text use the same operand grammar and settings for each command.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Command> for every command in help order.

=head2 of

Returns the command of a given name, or an undefined value when the name is unknown.

=head2 switches

Returns the spellings, answers and descriptions of the global help and version options.

=cut
