package Test::Mutation::CLI;
use v5.36;
use Cwd             ();
use Errno           ();
use File::Path      ();
use File::Spec      ();
use Getopt::Long    ();
use List::Util      ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef Bool CodeRef Dict Enum FileHandle GlobRef HashRef InstanceOf Int Maybe Slurpy Str);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);
use Test::Mutation::Config;
use Test::Mutation::Host;
use Test::Mutation::Interrupted;
use Test::Mutation::Merge;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Project;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Html;
use Test::Mutation::Report::Json;
use Test::Mutation::Report::Patch;
use Test::Mutation::Report::Progress;
use Test::Mutation::Report::Terminal;
use Test::Mutation::Runner;

our $VERSION = '0.001';

my %COMMAND =
  ( run => \&_run, list => \&_list, show => \&_show, exec => \&_exec, merge => \&_merge, mutators => \&_mutators );

signature_for main => ( positional => [ Slurpy [ ArrayRef [Str] ] ], returns => Int );

# A standard stream of the process may be closed, and the command still ends with a status.
my $STREAM = FileHandle | GlobRef;

# The facts that the command reads from its process, so that a caller may give other ones.
my $WORLD = Dict [
    cwd        => Maybe [Str],
    env        => HashRef [ Maybe [Str] ],
    out        => $STREAM,
    err        => $STREAM,
    out_tty    => Bool,
    err_tty    => Bool,
    clock      => CodeRef,
    processors => CodeRef,
];
my $REFUSED    = Dict [ refused => Dict [ status => Int, text => Str ] ];
my $INVOCATION = $REFUSED | Dict [
    command    => Enum [qw(run list show exec merge mutators help version)],
    directory  => Maybe [Str],
    config     => Maybe [ InstanceOf ['Test::Mutation::Config'] ],
    operands   => ArrayRef [Str],
    processors => Maybe [ Dict [ count => PositiveInt, source => Str ] ],
];

my $HELP = <<'TEXT';
Usage: mutation [run] [options]
       mutation list [options]
       mutation show ID [options]
       mutation exec ID -- COMMAND [ARGUMENT...]
       mutation merge FILE... [options]
       mutation mutators

Commands:
  run       Measure how many mutants the tests detect (the default)
  list      Print the mutants without running a test
  show      Print one mutant as a unified diff
  exec      Run a command with one mutant active
  merge     Report one run from the mutation.json of every part of --shard
  mutators  Print the name, the profile, and the description of every mutator

Options:
  --root, -C DIR        Run as if mutation had started in DIR
  --jobs, -j N          Test processes to run side by side
  --min-score N         Fail when the score is below N percent
  --format NAME         Report to write: terminal, json, html; repeatable
  --report-dir DIR      Directory for the report files
  --perl PATH           Interpreter that runs the tests
  --source GLOB         Files to mutate; repeatable
  --test GLOB           Test files; repeatable
  --profile NAME        Mutator profile: default or extended
  --enable NAME         Add a mutator; repeatable
  --disable NAME        Remove a mutator; repeatable
  --coverage MODE       Select tests by line or by file
  --timeout-factor N    Time limit as a multiple of the unmodified duration
  --timeout-floor N     Smallest time limit in seconds
  --in-place            Run the tests in the project itself, not in copies of it
  --keep-work           Keep the work directory after the run
  --mutant ID           Run the named mutant; repeatable
  --since REVISION      Cover the lines changed since a Git revision
  --shard K/N           Cover part K of N equal parts of the mutants
  --no-equivalence      Keep the mutants that compile to the original code
  --cache               Reuse the results of an earlier run where the inputs are unchanged
  --config FILE         Configuration file to read in place of mutation.toml
  --version             Print the version
  --help                Print this text
TEXT

sub main ($list) {
    my $world = {
        cwd        => Cwd::getcwd(),
        env        => \%ENV,
        out        => \*STDOUT,
        err        => \*STDERR,
        out_tty    => _terminal( \*STDOUT ),
        err_tty    => _terminal( \*STDERR ),
        clock      => \&Time::HiRes::time,
        processors => \&Test::Mutation::Host::processors,
    };
    return execute( plan( argv => $list, world => $world ), $world );
}

# A closed stream is no terminal, and the question to it would warn.
sub _terminal ($stream) {
    return defined fileno $stream && -t $stream ? 1 : 0;    ## no critic (InputOutput::ProhibitInteractiveTest)
}

# The first argument that the command answers without a look at the project.
my %ANSWER = ( '--version' => 'version', '--help' => 'help', '-h' => 'help' );

# What is wrong with the operands of a command, as the text of its refusal.
my %OPERAND_PROBLEM = (
    run      => sub (@operands) { return @operands ? "unexpected argument $operands[0]" : undef },
    list     => sub (@operands) { return },
    show     => sub (@operands) { return @operands     ? undef : 'show needs a mutant identifier' },
    exec     => sub (@operands) { return @operands > 1 ? undef : 'exec needs a mutant identifier and a command' },
    merge    => sub (@operands) { return @operands     ? undef : 'merge needs the report of every part' },
    mutators => sub (@operands) { return @operands     ? "unexpected argument $operands[0]" : undef },
);

sub _refused ($text) {
    return { refused => { status => 2, text => $text } };
}

signature_for plan => ( named => [ argv => ArrayRef [Str], world => $WORLD ], returns => $INVOCATION );

sub plan ($arg) {
    my $world     = $arg->world;
    my @arguments = $arg->argv->@*;

    # The directory comes first, so every later path and the configuration file are read from inside it.
    my $anywhere = Getopt::Long::Parser->new( config => [qw(pass_through no_ignore_case no_auto_abbrev)] );
    $anywhere->getoptionsfromarray( \@arguments, 'root|C=s' => \my $directory );
    my $inside = $world->{cwd};
    if ( defined $directory ) {
        $inside = _under( $inside, $directory );
        my $reason = _closed($inside);
        return _refused("mutation: cannot enter $directory: $reason\n") if defined $reason;
    }

    my $first   = @arguments ? $arguments[0] : q{};
    my $command = $ANSWER{$first} || ( $COMMAND{$first} ? $first : undef );
    shift @arguments if defined $command;
    $command = 'run' if !defined $command;
    my %plan =
      ( command => $command, directory => $directory, config => undef, operands => \@arguments, processors => undef );
    return \%plan if $ANSWER{$first};
    if ( $command ne 'mutators' ) {
        $plan{processors} = $world->{processors}->();
        ( $plan{config}, my $complaint ) = _config( \@arguments, $inside, $plan{processors}{count}, $world );
        return _refused($complaint) if !$plan{config};
    }
    my $problem = $OPERAND_PROBLEM{$command}->(@arguments);
    return defined $problem ? _refused("mutation: $problem\n") : \%plan;
}

# A path as the command reads it once it stands in the directory.
# A process whose directory is gone has none, and an empty path names no file.
sub _under ( $directory, $path ) {
    return defined $directory && length $path ? File::Spec->rel2abs( $path, $directory ) : $path;
}

# The plan changes no directory, so it asks what a change of directory would answer.
sub _closed ($directory) {
    my $errno = !stat($directory) ? 0 + $! : !-d _ ? Errno::ENOTDIR : !-x _ ? Errno::EACCES : return;
    local $! = $errno;
    return "$!";
}

signature_for execute => ( positional => [ $INVOCATION, $WORLD ], returns => Int );

sub execute ( $invocation, $world ) {
    if ( my $refused = $invocation->{refused} ) {
        print { $world->{err} } $refused->{text};
        return $refused->{status};
    }
    my ( $command, $directory ) = $invocation->@{qw(command directory)};
    if ( defined $directory ) {

        # A relative entry of the module search path names another place after the change of directory.
        @INC = map { ref $_ ? $_ : File::Spec->rel2abs($_) } @INC;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return _usage( $world, "cannot enter $directory: $!" ) if !chdir _under( $world->{cwd}, $directory );
    }

    if ( $command eq 'version' ) {
        say { $world->{out} } "mutation $VERSION";
        return 0;
    }
    if ( $command eq 'help' ) {
        print { $world->{out} } $HELP;
        return 0;
    }
    my $status = eval { $COMMAND{$command}->( $invocation, $world ) };
    return $status if defined $status;
    my $error = $@;
    if ( eval { $error->isa('Test::Mutation::Interrupted') } ) {
        print { $world->{err} } 'mutation: interrupted by SIG', $error->signal, "\n";
        return $error->exit_status;
    }
    print { $world->{err} } 'mutation: ', _first_line($error), "\n";
    return 4;
}

my %SETTING_OF_OPTION = (
    'jobs|j=i'         => 'jobs',
    'min-score=f'      => 'threshold_break',
    'format=s@'        => 'formats',
    'report-dir=s'     => 'report_directory',
    'perl=s'           => 'perl',
    'source=s@'        => 'source_include',
    'test=s@'          => 'test_include',
    'profile=s'        => 'profile',
    'enable=s@'        => 'enable',
    'disable=s@'       => 'disable',
    'coverage=s'       => 'coverage',
    'timeout-factor=f' => 'timeout_factor',
    'timeout-floor=f'  => 'timeout_floor',
    'keep-work'        => 'keep_work',
    'mutant=s@'        => 'only',
    'since=s'          => 'since',
    'shard=s'          => 'shard',
    'equivalence!'     => 'equivalence',
    'cache!'           => 'cache',
    'in-place!'        => 'in_place',
);

# The settings of a command, or nothing and the text that refuses its arguments.
sub _config ( $arguments, $directory, $processors, $world ) {
    my ( %cli, $file );
    my $complaints = q{};
    my $parser     = Getopt::Long::Parser->new( config => [qw(bundling no_ignore_case)] );
    my $parsed     = do {

        # The parser reports through a warning, and a plan prints nothing.
        local $SIG{__WARN__} = sub ($text) { $complaints .= $text };
        $parser->getoptionsfromarray(
            $arguments,
            ( map { $_ => \$cli{ $SETTING_OF_OPTION{$_} } } keys %SETTING_OF_OPTION ),
            'config=s' => \$file,
        );
    };
    return ( undef, $complaints ) if !$parsed;
    delete @cli{ grep { !defined $cli{$_} } keys %cli };
    my $config = eval {
        Test::Mutation::Config->from_layers(
            root     => defined $directory ? Cwd::abs_path($directory) : undef,
            defaults => {
                jobs    => Test::Mutation::Project::default_jobs($processors),
                formats => [ qw(terminal json html), _inside_github_actions( $world->{env} ) ? 'github' : () ],
            },
            file => _configuration_file( $file, $directory ),
            cli  => \%cli,
        );
    };
    return $config ? $config : ( undef, 'mutation: ' . _first_line($@) . "\n" );
}

sub _inside_github_actions ($env) {
    my $value = $env->{GITHUB_ACTIONS};
    return defined $value && $value eq 'true' ? 1 : 0;
}

sub _configuration_file ( $named, $directory ) {
    my $path = defined $named ? $named : 'mutation.toml';
    my $file = _under( $directory, $path );
    return {} if !defined $named && !-e $file;
    my $parsed = eval { Test::Mutation::Config::read_file($file) };
    return $parsed if $parsed;

    # The plan reads the file through the directory, and the message names it as the user did.
    my $error = $@;
    $error =~ s/\Q$file\E/$path/ if $file ne $path;
    die $error;    ## no critic (ErrorHandling::RequireCarping)
}

sub _first_line ($error) {
    my $message = eval { $error->message };
    my ($line)  = split /\n/, defined $message ? $message : "$error";
    $line =~ s/ at \S+ line \d+[.]?\z//;
    return $line;
}

sub _run ( $invocation, $world ) {
    my $config = $invocation->{config};
    print { $world->{err} } Test::Mutation::Host::describe( $invocation->{processors} ), "\n";
    my $result = Test::Mutation::Runner::run( $config, _progress( $world->{err}, $world->{err_tty} ) );
    _report( $result, $config, $world );
    print { $world->{err} } 'mutation: interrupted by SIG', $result->interrupted, "\n" if defined $result->interrupted;
    return _exit_status( $result, $config );
}

sub _progress ( $errors, $in_place ) {
    my ( %counts, $total );
    my $done = 0;
    return sub ( $event, $data ) {
        if ( $event eq 'analyzed' ) {
            $total = $data->{mutants};
            printf {$errors} "%s in %s, %s\n", _plural( $total, 'mutant' ), _plural( $data->{files}, 'file' ),
              _plural( $data->{tests}, 'test' );
        }
        elsif ( $event eq 'baseline' ) {
            printf {$errors} "The unmodified run passed: %s, %s\n", _plural( $data->{tests}, 'test' ),
              _plural( $data->{jobs}, 'job' );
        }
        elsif ( $event eq 'mutant' ) {
            $counts{ $data->{status} }++;
            $done++;
            print {$errors} Test::Mutation::Report::Progress::update( $done, $total, \%counts, $in_place );
        }
        return;
    };
}

my %FILE_REPORT = (
    json => [ 'mutation.json', \&Test::Mutation::Report::Json::render ],
    html => [ 'mutation.html', \&Test::Mutation::Report::Html::render ],
);

sub _report ( $result, $config, $world ) {
    my %wanted = map { $_ => 1 } $config->formats->@*;
    print { $world->{out} } Test::Mutation::Report::Terminal::render( $result, color => 0 ) if $wanted{terminal};

    my @written;
    for my $format ( grep { $wanted{$_} } qw(json html) ) {
        my ( $name, $render ) = $FILE_REPORT{$format}->@*;
        my $directory = $config->report_directory;
        my $target    = File::Spec->rel2abs( $directory, $config->root );
        File::Path::make_path($target);
        my $text = $render->( $result, high => $config->threshold_high, low => $config->threshold_low );
        open my $handle, '>:encoding(UTF-8)', "$target/$name" or die "cannot write $directory/$name: $!\n";
        print {$handle} $text or die "cannot write $directory/$name: $!\n";
        close $handle         or die "cannot close $directory/$name: $!\n";
        push @written, "$directory/$name";
    }
    print { $world->{out} } 'Reports: ', join( ', ', @written ), "\n" if @written;
    _report_to_github( $result, $world ) if $wanted{github};
    return;
}

sub _report_to_github ( $result, $world ) {
    print { $world->{out} } Test::Mutation::Report::GitHub::annotations($result);
    my $path = $world->{env}{GITHUB_STEP_SUMMARY};
    return if !defined $path || !length $path;
    open my $handle, '>>:encoding(UTF-8)', $path or die "cannot write $path: $!\n";
    print {$handle} Test::Mutation::Report::GitHub::summary($result) or die "cannot write $path: $!\n";
    close $handle                                                    or die "cannot close $path: $!\n";
    return;
}

sub _exit_status ( $result, $config ) {
    return Test::Mutation::Interrupted->new( signal => $result->interrupted )->exit_status
      if defined $result->interrupted;
    return 3 if $result->baseline_failures->@*;
    return 4 if !$result->conclusive;
    my $score = $result->tally->{score};
    my $floor = $config->threshold_break;
    return 1 if defined $floor && defined $score && $score < $floor;
    return 0;
}

sub _heading ($mutant) {
    my $place = sprintf '%s:%d:%d', $mutant->path, $mutant->from->@*;
    return join q{  }, $mutant->id, $place, $mutant->mutator, $mutant->description;
}

sub _list ( $invocation, $world ) {
    my @mutants = Test::Mutation::Runner::analyze( $invocation->{config} )->{mutants}->@*;
    say { $world->{out} } _heading($_), $_->suppressed ? '  (suppressed)' : q{} for @mutants;
    say { $world->{out} } _plural( scalar @mutants, 'mutant' );
    return 0;
}

sub _usage ( $world, $message ) {
    print { $world->{err} } "mutation: $message\n";
    return 2;
}

sub _find ( $analysis, $identifier ) {
    my @matches = grep { substr( $_->id, 0, length $identifier ) eq $identifier } $analysis->{mutants}->@*;
    return $matches[0] if @matches == 1;
    die( ( @matches ? 'more than one mutant has' : 'no mutant has' ) . " the identifier $identifier\n" );
}

sub _show ( $invocation, $world ) {
    my $analysis = Test::Mutation::Runner::analyze( $invocation->{config} );
    my $mutant   = eval { _find( $analysis, $invocation->{operands}[0] ) } or return _usage( $world, _first_line($@) );
    say { $world->{out} } _heading($mutant);
    print { $world->{out} } Test::Mutation::Report::Patch::render(
        text   => $analysis->{sources}{ $mutant->path }->text,
        mutant => $mutant
    );
    return 0;
}

sub _exec ( $invocation, $world ) {
    my $config = $invocation->{config};
    my ( $identifier, @command ) = $invocation->{operands}->@*;
    my $analysis = Test::Mutation::Runner::analyze($config);
    my $mutant   = eval { _find( $analysis, $identifier ) } or return _usage( $world, _first_line($@) );
    return Test::Mutation::Runner::run_command( $config, $analysis->{sources}{ $mutant->path }, $mutant, \@command );
}

sub _read_report ($path) {
    open my $handle, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
    local $/ = undef;
    my $text = readline $handle;
    close $handle or die "cannot close $path: $!\n";
    my $result = eval { Test::Mutation::Report::Json::parse( defined $text ? $text : q{} ) };
    return $result if $result;
    die "$path: " . _first_line($@) . "\n";
}

sub _merge ( $invocation, $world ) {
    my $config = $invocation->{config};
    my $result = eval {
        Test::Mutation::Merge::merge(
            [ map { { name => $_, result => _read_report($_) } } $invocation->{operands}->@* ] );
    }
      or return _usage( $world, _first_line($@) );
    _report( $result, $config, $world );
    return _exit_status( $result, $config );
}

sub _mutators ( $invocation, $world ) {
    my @mutators = Test::Mutation::Mutator::Catalog::mutators()->@*;
    my $name     = List::Util::max( map { length $_->name } @mutators );
    my $profile  = List::Util::max( map { length $_->profile } @mutators );
    printf { $world->{out} } "%-*s  %-*s  %s\n", $name, $_->name, $profile, $_->profile, $_->description for @mutators;
    return 0;
}

sub _plural ( $count, $noun ) {
    return $count == 1 ? "$count $noun" : "$count ${noun}s";
}

1;

__END__

=head1 NAME

Test::Mutation::CLI - the mutation command

=head1 SYNOPSIS

    exit Test::Mutation::CLI::main(@ARGV);

=head1 FUNCTIONS

=head2 main

Runs the command named by the first argument, C<run> when there is none, and returns the exit status.
The call plans with the facts of the process and then carries the plan out.

=head2 plan

    my $invocation = Test::Mutation::CLI::plan( argv => \@ARGV, world => $world );

Returns what the command would do, and changes nothing: no directory, no search path, and no file.
C<world> holds the facts that the command reads from its process.
C<cwd> is the working directory, C<env> the environment, and C<out> and C<err> are the handles of the two streams.
C<out_tty> and C<err_tty> state whether a stream is a terminal.
C<clock> returns the time.
C<processors> returns the count of processors that a run may use and its source, as L<Test::Mutation::Host/processors> does.

A plan to act holds the C<command>, the C<directory> that C<--root> names, the C<config>, and the C<operands>.
A plan with settings also holds the C<processors> of its world, and a run names them in its first line.
A plan to refuse holds C<refused>, with the exit C<status> and the C<text> for standard error.
The plan reads the configuration file, and the function dies on an error that no check of the arguments foresees.

=head2 execute

    my $status = Test::Mutation::CLI::execute( $invocation, $world );

Carries a plan out and returns the exit status.
A plan to refuse prints its text.
A plan to act enters the directory, runs the command, and prints to the streams of the world.

=cut
