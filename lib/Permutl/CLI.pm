package Permutl::CLI;
use v5.36;
use Cwd             ();
use Getopt::Long    ();
use Types::Standard qw(ArrayRef Int Slurpy Str);
use Type::Params    qw(signature_for);
use Permutl::Config;
use Permutl::Project;
use Permutl::Report::Terminal;
use Permutl::Runner;

our $VERSION = '0.001';

my %COMMAND = ( run => \&_run );

signature_for main => ( positional => [ Slurpy [ ArrayRef [Str] ] ], returns => Int );

sub main ($list) {
    my @arguments = $list->@*;
    my $command   = @arguments && $COMMAND{ $arguments[0] } ? shift @arguments : 'run';
    return $COMMAND{$command}->(@arguments);
}

sub _config (@arguments) {
    my %cli;
    my $parser = Getopt::Long::Parser->new( config => [qw(bundling no_ignore_case)] );
    $parser->getoptionsfromarray(
        \@arguments,
        'jobs|j=i'    => \$cli{jobs},
        'min-score=f' => \$cli{threshold_break},
    ) or return;
    delete @cli{ grep { !defined $cli{$_} } keys %cli };
    my $processors = Permutl::Project::cpu_count();
    return Permutl::Config->from_layers(
        root     => Cwd::getcwd(),
        defaults => { jobs => $processors > 1 ? $processors - 1 : 1 },
        file     => {},
        cli      => \%cli,
    );
}

sub _run (@arguments) {
    my $config = _config(@arguments) or return 2;
    my $result = Permutl::Runner::run(
        $config,
        sub ( $event, $data ) {
            return if $event ne 'analyzed';
            printf {*STDERR} "%s in %s, %s\n", _plural( $data->{mutants}, 'mutant' ), _plural( $data->{files}, 'file' ),
              _plural( $data->{tests}, 'test' );
            return;
        }
    );
    print Permutl::Report::Terminal::render( $result, color => 0 );
    return _exit_status( $result, $config );
}

sub _exit_status ( $result, $config ) {
    return 3 if $result->baseline_failures->@*;
    return 4 if !$result->conclusive;
    my $score = $result->tally->{score};
    my $floor = $config->threshold_break;
    return 1 if defined $floor && defined $score && $score < $floor;
    return 0;
}

sub _plural ( $count, $noun ) {
    return $count == 1 ? "$count $noun" : "$count ${noun}s";
}

1;

__END__

=head1 NAME

Permutl::CLI - the permutl command

=head1 SYNOPSIS

    exit Permutl::CLI::main(@ARGV);

=head1 FUNCTIONS

=head2 main

Runs the command named by the first argument, C<run> when there is none, and returns the exit status.

=cut
