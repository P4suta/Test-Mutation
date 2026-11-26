package World;
use v5.36;
use Cwd        ();
use File::Spec ();
use Test::Mutation::CLI;

my $PROCESSORS = 4;

# The count of processors of every world, unless a case gives another one.
sub processors () {
    return $PROCESSORS;
}

# The facts that the command reads from its process, each with a fixed answer.
# A harness that copied the environment of its machine would find other violations on another machine.
sub facts (%fact) {
    return (
        cwd        => Cwd::getcwd(),
        env        => {},
        out_tty    => 0,
        err_tty    => 0,
        clock      => sub { 0 },
        processors => sub { { count => $PROCESSORS, source => 'online' } },
        %fact,
    );
}

# One observation of a command line: the plan, and what the command prints and returns when it runs.
# `run` names the plans that the observation carries out: every plan, or the ones that start no analysis and no test.
sub observe ( $argv, %fact ) {
    my $run = delete $fact{run} || 'all';
    my ( $out, $err ) = ( q{}, q{} );
    open my $out_handle, '>:encoding(UTF-8)', \$out or die "out: $!";
    open my $err_handle, '>:encoding(UTF-8)', \$err or die "err: $!";
    my $world = { facts(%fact), out => $out_handle, err => $err_handle };
    my ( @warnings, $exit );
    local $SIG{__WARN__} = sub ($text) { push @warnings, $text };

    my $plan  = eval { Test::Mutation::CLI::plan( argv => $argv, world => $world ) };
    my $died  = $plan ? undef : "$@";
    my $cheap = $plan && ( $plan->{refused} || $plan->{command} =~ /\A(?:help|version|mutators)\z/ );
    if ( $plan && ( $run eq 'all' || $cheap ) ) {
        $exit = eval { Test::Mutation::CLI::execute( $plan, $world ) };
        $died = "$@" if !defined $exit;
    }
    close $out_handle or die "out: $!";
    close $err_handle or die "err: $!";
    return {
        argv     => $argv,
        plan     => $plan,
        died     => $died,
        exit     => $exit,
        stdout   => $out,
        stderr   => $err,
        warnings => \@warnings,
    };
}

1;
