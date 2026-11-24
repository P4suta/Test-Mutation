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
    open my $out_handle, '>', \$out or die "out: $!";
    open my $err_handle, '>', \$err or die "err: $!";
    my $world = { facts(%fact), out => $out_handle, err => $err_handle };
    my $here  = Cwd::getcwd();
    my ( @warnings, $exit );
    local $SIG{__WARN__} = sub ($text) { push @warnings, $text };

    # The command stands in its project, and the harness enters it for the command.
    # An entry of the search path that counts from the directory of the harness keeps its place.
    local @INC = map { ref $_ ? $_ : File::Spec->rel2abs($_) } @INC;
    my $plan  = eval { Test::Mutation::CLI::plan( argv => $argv, world => $world ) };
    my $died  = $plan ? undef : "$@";
    my $cheap = $plan && ( $plan->{refused} || $plan->{command} =~ /\A(?:help|version|mutators)\z/ );
    if ( $plan && ( $run eq 'all' || $cheap ) ) {
        if ( defined $world->{cwd} ) {
            chdir $world->{cwd} or die "chdir $world->{cwd}: $!";
        }
        $exit = eval { Test::Mutation::CLI::execute( $plan, $world ) };
        $died = "$@" if !defined $exit;
        chdir $here or die "chdir $here: $!";
    }
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
