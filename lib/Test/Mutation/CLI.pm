package Test::Mutation::CLI;
use v5.36;
use Cwd             ();
use Errno           ();
use File::Spec      ();
use Getopt::Long    ();
use List::Util      ();
use Scalar::Util    ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef Bool CodeRef Dict Enum FileHandle GlobRef HashRef InstanceOf Int Maybe Slurpy Str);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);
use overload               ();
use Test::Mutation::Config;
use Test::Mutation::Error;
use Test::Mutation::Exit;
use Test::Mutation::Host;
use Test::Mutation::Interrupted;
use Test::Mutation::Merge;
use Test::Mutation::Message;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Project;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Html;
use Test::Mutation::Report::Json;
use Test::Mutation::Report::Patch;
use Test::Mutation::Report::Progress;
use Test::Mutation::Report::Terminal;
use Test::Mutation::Runner;
use Test::Mutation::Signals;
use Test::Mutation::Tree;
use Test::Mutation::Try;

our $VERSION = '0.001';

my $TYPED        = InstanceOf ['Test::Mutation::Error'];
my $INTERRUPTION = InstanceOf ['Test::Mutation::Interrupted'];

# The command that mutation exec runs owns every other status, so a failure of exec itself has one status of its own.
my %IN_EXEC = ( environment => 'exec-failed', internal => 'exec-failed' );

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
    return Test::Mutation::Signals::watch( sub { execute( plan( argv => $list, world => $world ), $world ) } );
}

# A closed stream is no terminal, and the question to it would warn.
sub _terminal ($stream) {
    return defined fileno $stream && -t $stream ? 1 : 0;    ## no critic (InputOutput::ProhibitInteractiveTest)
}

# The first argument that the command answers without a look at the project.
my %ANSWER = ( '--version' => 'version', '--help' => 'help', '-h' => 'help' );

# The operands that a command refuses, each with the error of its refusal.
my %REFUSE_OPERANDS = (
    run => sub (@operands) {
        Test::Mutation::Error::raise( 'argument-unexpected', argument => $operands[0] ) if @operands;
        return;
    },
    list => sub (@operands) { return },
    show => sub (@operands) {
        Test::Mutation::Error::raise('show-without-identifier') if !@operands;
        return;
    },
    exec => sub (@operands) {
        Test::Mutation::Error::raise('exec-without-command') if @operands < 2;
        return;
    },
    merge => sub (@operands) {
        Test::Mutation::Error::raise('merge-without-report') if !@operands;
        return;
    },
    mutators => sub (@operands) {
        Test::Mutation::Error::raise( 'argument-unexpected', argument => $operands[0] ) if @operands;
        return;
    },
);

# What an exception calls for: the exit status and the line for standard error.
sub _failure ( $error, $command ) {
    return { status => $error->exit_status, text => Test::Mutation::Message::line( $error->message ) }
      if $INTERRUPTION->check($error);
    my ( $kind, $text ) =
      $TYPED->check($error)
      ? ( $error->kind, $error->message )
      : ( 'internal', Test::Mutation::Message::text_of( 'internal-error', text => _first_line($error) ) );
    my $outcome = $command eq 'exec' && $IN_EXEC{$kind} ? $IN_EXEC{$kind} : $kind;
    return { status => Test::Mutation::Exit::of($outcome), text => Test::Mutation::Message::line($text) };
}

signature_for plan => ( named => [ argv => ArrayRef [Str], world => $WORLD ], returns => $INVOCATION );

sub plan ($arg) {
    my $attempt = Test::Mutation::Try::attempt( sub { _planned( $arg->argv, $arg->world ) } );
    return exists $attempt->{value} ? $attempt->{value} : { refused => _failure( $attempt->{error}, 'plan' ) };
}

sub _planned ( $argv, $world ) {
    my @arguments = $argv->@*;

    # The directory comes first, so every later path and the configuration file are read from inside it.
    my $anywhere = Getopt::Long::Parser->new( config => [qw(pass_through no_ignore_case no_auto_abbrev)] );
    $anywhere->getoptionsfromarray( \@arguments, 'root|C=s' => \my $directory );
    my $inside = $world->{cwd};
    if ( defined $directory ) {
        $inside = _under( $inside, $directory );
        my $reason = _closed($inside);
        Test::Mutation::Error::raise( 'directory-closed', directory => $directory, reason => $reason )
          if defined $reason;
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
        my $settings = _config( \@arguments, $inside, $plan{processors}{count}, $world );
        return $settings if $settings->{refused};
        $plan{config} = $settings->{config};
    }
    $REFUSE_OPERANDS{$command}->(@arguments);
    return \%plan;
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

    # The one place of the command that ends an exception: each kind has its status and its line.
    my $attempt = Test::Mutation::Try::attempt( sub { _carried_out( $invocation, $world ) }, 'interruption' );
    return $attempt->{value} if exists $attempt->{value};
    my $failure = _failure( $attempt->{error}, $invocation->{command} );
    print { $world->{err} } $failure->{text};
    return $failure->{status};
}

sub _carried_out ( $invocation, $world ) {
    my ( $command, $directory ) = $invocation->@{qw(command directory)};
    if ( defined $directory ) {

        # A relative entry of the module search path names another place after the change of directory.
        @INC = map { ref $_ ? $_ : File::Spec->rel2abs($_) } @INC;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        chdir _under( $world->{cwd}, $directory )
          or Test::Mutation::Error::raise( 'directory-closed', directory => $directory, reason => "$!" );
    }

    if ( $command eq 'version' ) {
        say { $world->{out} } "mutation $VERSION";
        return 0;
    }
    if ( $command eq 'help' ) {
        print { $world->{out} } $HELP;
        return 0;
    }
    my $status = $COMMAND{$command}->( $invocation, $world );

    # A signal that arrived after the last check of the command still ends it with the status of the signal.
    Test::Mutation::Signals::check();
    return $status;
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

# The refusal of the settings of a command, in the words of the option parser or of the type library.
# The settings table gives each setting a message of its own.
sub _refused_settings ($text) {
    return { refused => { status => Test::Mutation::Exit::of('usage'), text => $text } };
}

# The settings of a command, or the refusal of its arguments.
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
    return _refused_settings($complaints) if !$parsed;
    delete @cli{ grep { !defined $cli{$_} } keys %cli };
    my $settings = _configuration_file( $file, $directory );
    my $build    = sub {
        Test::Mutation::Config->from_layers(
            root     => defined $directory ? Cwd::abs_path($directory) : undef,
            defaults => {
                jobs    => Test::Mutation::Project::default_jobs($processors),
                formats => [ qw(terminal json html), _inside_github_actions( $world->{env} ) ? 'github' : () ],
            },
            file => $settings,
            cli  => \%cli,
        );
    };
    my $built = Test::Mutation::Try::attempt($build);
    return { config => $built->{value} } if exists $built->{value};
    return _refused_settings( Test::Mutation::Message::line( _first_line( $built->{error} ) ) );
}

sub _inside_github_actions ($env) {
    my $value = $env->{GITHUB_ACTIONS};
    return defined $value && $value eq 'true' ? 1 : 0;
}

sub _configuration_file ( $named, $directory ) {
    my $path = defined $named ? $named : 'mutation.toml';
    my $file = _under( $directory, $path );
    return {} if !defined $named && !-e $file;

    # The plan reads the file through the directory, and the message names it as the user did.
    return Test::Mutation::Config::read_file( $file, $path );
}

# The first line of an exception without the place in the code that raised it.
# A value that has no text of its own gives the name of its type.
sub _first_line ($error) {
    my $says = Scalar::Util::blessed($error) && $error->can('message');
    return ref $error if ref $error && !$says && !overload::Method( $error, q{""} );
    my ($line) = ( split( /\n/, $says ? $error->message : "$error" ), q{} );
    return $line =~ s/ at \S+ line \d+[.]?\z//r;
}

sub _run ( $invocation, $world ) {
    my $config = $invocation->{config};
    print { $world->{err} } Test::Mutation::Host::describe( $invocation->{processors} ), "\n";
    my $result = Test::Mutation::Runner::run( $config, _progress( $world->{err}, $world->{err_tty} ) );
    _report( $result, $config, $world );
    return _concluded( $result, $config, $world );
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
        Test::Mutation::Tree::make($target);
        my $text = $render->( $result, high => $config->threshold_high, low => $config->threshold_low );
        _write( "$target/$name", "$directory/$name", '>', $text );
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
    _write( $path, $path, '>>', Test::Mutation::Report::GitHub::summary($result) );
    return;
}

# Writes a text to a file, which an error names as the user knows it.
sub _write ( $path, $name, $mode, $text ) {
    open my $handle, "$mode:encoding(UTF-8)", $path
      or Test::Mutation::Error::raise( 'file-unwritable', path => $name, reason => "$!" );
    print {$handle} $text or Test::Mutation::Error::raise( 'file-unwritable', path => $name, reason => "$!" );
    close $handle         or Test::Mutation::Error::raise( 'file-unclosable', path => $name, reason => "$!" );
    return;
}

sub _ended ( $world, $status, $text ) {
    print { $world->{err} } Test::Mutation::Message::line($text);
    return $status;
}

# The outcome of a result: its exit status, and for every outcome but success the line that names it.
sub _concluded ( $result, $config, $world ) {
    my $signal = $result->interrupted;
    my $failed = scalar $result->baseline_failures->@*;
    my $score  = $result->tally->{score};
    my $floor  = $config->threshold_break;
    return _ended(
        $world,
        Test::Mutation::Exit::of_signal($signal),
        Test::Mutation::Message::text_of( 'interrupted', signal => $signal )
    ) if defined $signal;
    return _ended(
        $world,
        Test::Mutation::Exit::of('baseline-failed'),
        Test::Mutation::Message::text_of( 'baseline-failed', failed => $failed )
    ) if $failed;
    return _ended( $world, Test::Mutation::Exit::of('inconclusive'), Test::Mutation::Message::text_of('inconclusive') )
      if !$result->conclusive;
    return _ended(
        $world,
        Test::Mutation::Exit::of('below-gate'),
        Test::Mutation::Message::text_of( 'below-gate', score => sprintf( '%.1f', $score ), gate => $floor )
    ) if defined $floor && defined $score && $score < $floor;
    return Test::Mutation::Exit::of('success');
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

sub _find ( $analysis, $identifier ) {
    my @matches = grep { substr( $_->id, 0, length $identifier ) eq $identifier } $analysis->{mutants}->@*;
    Test::Mutation::Error::raise( 'mutant-unknown',   identifier => $identifier ) if !@matches;
    Test::Mutation::Error::raise( 'mutant-ambiguous', identifier => $identifier ) if @matches > 1;
    return $matches[0];
}

sub _show ( $invocation, $world ) {
    my $analysis = Test::Mutation::Runner::analyze( $invocation->{config} );
    my $mutant   = _find( $analysis, $invocation->{operands}[0] );
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
    my $mutant   = _find( $analysis, $identifier );
    return Test::Mutation::Runner::run_command( $config, $analysis->{sources}{ $mutant->path }, $mutant, \@command );
}

sub _read_report ($path) {
    open my $handle, '<:encoding(UTF-8)', $path
      or Test::Mutation::Error::raise( 'input-unreadable', path => $path, reason => "$!" );
    local $/ = undef;
    my $text = readline $handle;
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    my $parsed =
      Test::Mutation::Try::attempt( sub { Test::Mutation::Report::Json::parse( defined $text ? $text : q{} ) } );
    return $parsed->{value} if exists $parsed->{value};
    return Test::Mutation::Error::raise( 'input-malformed', path => $path, reason => _first_line( $parsed->{error} ) );
}

sub _merge ( $invocation, $world ) {
    my $config = $invocation->{config};
    my $result = Test::Mutation::Merge::merge(
        [ map { { name => $_, result => _read_report($_) } } $invocation->{operands}->@* ] );
    _report( $result, $config, $world );
    return _concluded( $result, $config, $world );
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
