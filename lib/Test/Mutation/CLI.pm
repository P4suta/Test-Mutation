package Test::Mutation::CLI;
use v5.36;
use Cwd          ();
use Errno        ();
use File::Spec   ();
use List::Util   ();
use Scalar::Util ();
use Time::HiRes  ();
use Types::Standard
  qw(ArrayRef Bool CodeRef Dict Enum FileHandle GlobRef HashRef InstanceOf Int Maybe Optional Slurpy Str);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);
use overload               ();
use Test::Mutation::CLI::Arguments;
use Test::Mutation::Commands;
use Test::Mutation::Config;
use Test::Mutation::Error;
use Test::Mutation::Exit;
use Test::Mutation::Host;
use Test::Mutation::Interrupted;
use Test::Mutation::Merge;
use Test::Mutation::Message;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Html;
use Test::Mutation::Report::Json;
use Test::Mutation::Report::Patch;
use Test::Mutation::Report::Progress;
use Test::Mutation::Report::Terminal;
use Test::Mutation::Runner;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Signals;
use Test::Mutation::Tree;
use Test::Mutation::Try;

our $VERSION = '0.001';

my $TYPED        = InstanceOf ['Test::Mutation::Error'];
my $INTERRUPTION = InstanceOf ['Test::Mutation::Interrupted'];

# The command that mutation exec runs owns every other status, so exec reports its own failures with the statuses of env.
# A command that exists nowhere or that the system refuses to run has a status of its own, and every other failure has 125.
my %OF_EXEC_COMMAND = ( 'command-not-found' => 'command-not-found', 'command-not-runnable' => 'command-not-runnable' );
my %IN_EXEC         = ( environment         => 'exec-failed',       internal               => 'exec-failed' );

my %COMMAND = (
    run      => \&_run,
    baseline => \&_baseline,
    settings => \&_settings,
    list     => \&_list,
    show     => \&_show,
    exec     => \&_exec,
    merge    => \&_merge,
    mutators => \&_mutators
);

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
    command    => Enum [ ( map { $_->name } Test::Mutation::Commands::rows()->@* ), 'version' ],
    directory  => Maybe [Str],
    config     => Maybe [ InstanceOf ['Test::Mutation::Config'] ],
    operands   => ArrayRef [Str],
    selection  => Optional [ InstanceOf ['Test::Mutation::Selection'] ],
    topic      => Optional [Str],
    processors => Maybe [ Dict [ count => PositiveInt, source => Str ] ],
];

# The words of an option in the help text: its spellings and the placeholder of its value.
sub _option_words ($setting) {
    my @spelled = (
        $setting->flag,
        ( defined $setting->short  ? $setting->short          : () ),
        ( $setting->kind eq 'flag' ? '--no-' . $setting->name : () ),
    );
    return join q{ }, join( q{, }, @spelled ), ( defined $setting->placeholder ? $setting->placeholder : () );
}

sub _help ($command) {
    my @commands = Test::Mutation::Commands::rows()->@*;
    my @rows     = $command ? ($command) : @commands;
    my $text     = 'Usage: ' . join( "\n       ", map { $_->usage } @rows ) . "\n";
    if ( !$command ) {
        my $width = List::Util::max( map { length $_->name } @commands );
        $text .= "\nCommands:\n" . join q{}, map { sprintf "  %-*s  %s\n", $width, $_->name, $_->summary } @commands;
    }
    my @options = map { [ _option_words($_), $_->help ] }
      grep { $_->offers('line') && ( !$command || $command->accepts( $_->name ) ) }
      Test::Mutation::Settings::rows()->@*;
    push @options, map { [ join( q{, }, $_->{words}->@* ), $_->{summary} ] } Test::Mutation::Commands::switches()->@*;
    my $width = List::Util::max( map { length $_->[0] } @options );
    return $text . "\nOptions:\n" . join q{}, map { sprintf "  %-*s  %s\n", $width, $_->@* } @options;
}

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

sub _unknown_command ($word) {
    my @names = ( map { $_->name } Test::Mutation::Commands::rows()->@* );
    push @names, map { $_->{words}->@* } Test::Mutation::Commands::switches()->@*;
    return Test::Mutation::Error::raise(
        'command-unknown',
        command => $word,
        nearest => Test::Mutation::Settings::nearest( $word, \@names )
    );
}

sub _operands ( $row, $parsed ) {
    my $operands = $parsed->{operands};
    my $grammar  = $row->operands;
    my %missing  = (
        identifier => sub { Test::Mutation::Error::raise('show-without-identifier') },
        execute    => sub { Test::Mutation::Error::raise('exec-without-command') },
        reports    => sub { Test::Mutation::Error::raise('merge-without-report') },
    );
    _unknown_command( $operands->[0] )
      if $grammar eq 'command' && $operands->@* && !Test::Mutation::Commands::of( $operands->[0] );
    my $missing_program = $grammar eq 'execute' && ( $parsed->{before_separator} != 1 || !length $operands->[1] );
    $missing{$grammar}->() if $operands->@* < $row->least || $missing_program;
    Test::Mutation::Error::raise( 'argument-unexpected', argument => $operands->[ $row->most ] )
      if defined $row->most && $operands->@* > $row->most;
    return;
}

# What an exception calls for: the exit status and the line for standard error.
sub _failure ( $error, $command ) {
    return { status => $error->exit_status, text => Test::Mutation::Message::line( $error->message ) }
      if $INTERRUPTION->check($error);
    my ( $kind, $text, $id ) =
      $TYPED->check($error)
      ? ( $error->kind, $error->message, $error->id )
      : ( 'internal', Test::Mutation::Message::text_of( 'internal-error', text => _first_line($error) ), q{} );
    my $outcome = $command eq 'exec' ? $OF_EXEC_COMMAND{$id} || $IN_EXEC{$kind} || $kind : $kind;
    return { status => Test::Mutation::Exit::of($outcome), text => Test::Mutation::Message::line($text) };
}

signature_for plan => ( named => [ argv => ArrayRef [Str], world => $WORLD ], returns => $INVOCATION );

sub plan ($arg) {
    my $attempt = Test::Mutation::Try::attempt( sub { _planned( $arg->argv, $arg->world ) } );
    return exists $attempt->{value} ? $attempt->{value} : { refused => _failure( $attempt->{error}, 'plan' ) };
}

sub _planned ( $argv, $world ) {
    my $parsed  = Test::Mutation::CLI::Arguments::parse( argv => $argv );
    my $command = $parsed->{command};
    my %plan    = (
        command    => $command,
        directory  => undef,
        config     => undef,
        operands   => $parsed->{operands},
        processors => undef
    );
    return \%plan if $parsed->{global};
    my $row = Test::Mutation::Commands::of($command);
    _operands( $row, $parsed );
    $plan{topic} = $plan{operands}[0] if $command eq 'help' && $plan{operands}->@*;
    return \%plan                     if $command eq 'help' || $command eq 'settings';

    # The directory comes first, so every later path and the configuration file are read from inside it.
    my $given  = $parsed->{given};
    my $root   = $given->{entries}{root};
    my $inside = $world->{cwd};
    if ($root) {
        my $directory = $plan{directory} = $root->{value};
        $inside = _under( $inside, $directory );
        my $reason = _closed($inside);
        Test::Mutation::Error::raise( 'directory-closed', directory => $directory, reason => $reason )
          if defined $reason;
    }
    if ( $command ne 'mutators' ) {
        Test::Mutation::Error::raise('working-directory-gone') if !defined $inside;
        $plan{processors} = $world->{processors}->();
        $plan{config}     = Test::Mutation::Settings::configure(
            root  => Cwd::abs_path($inside),
            given => $given,
            facts => { processors => $plan{processors}{count}, env => $world->{env} },
        );
    }
    if ( $row->operands eq 'paths' && $plan{operands}->@* ) {
        my $first = $plan{operands}[0];
        _unknown_command($first) if $parsed->{implicit} && $first !~ m{[./:]} && !-e _under( $inside, $first );
        $plan{selection} = Test::Mutation::Select::resolve(
            config   => $plan{config},
            operands => $plan{operands},
            reports  => $command eq 'run' ? 1 : 0,
            summary  => $world->{env}{GITHUB_STEP_SUMMARY}
        );
    }
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

    # The one place of the command that ends an exception: each kind has its status and its line.
    # A signal outranks every other outcome, so it ends the command whether it arrived in the plan, in the work, or after both.
    my $attempt = Test::Mutation::Try::attempt(
        sub {
            Test::Mutation::Signals::check();
            my $status = _carried_out( $invocation, $world );
            Test::Mutation::Signals::check();
            return $status;
        },
        'interruption'
    );
    return $attempt->{value} if exists $attempt->{value};
    my $failure = _failure( $attempt->{error}, $invocation->{command} );
    print { $world->{err} } $failure->{text};
    return $failure->{status};
}

sub _carried_out ( $invocation, $world ) {
    if ( my $refused = $invocation->{refused} ) {
        print { $world->{err} } $refused->{text};
        return $refused->{status};
    }
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
        my $selected = $invocation->{topic};
        print { $world->{out} } _help( defined $selected ? Test::Mutation::Commands::of($selected) : undef );
        return 0;
    }
    return $COMMAND{$command}->( $invocation, $world );
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
    my $result = Test::Mutation::Runner::run(
        $config,
        _progress( $world->{err}, $world->{err_tty}, $invocation->{processors} ),
        $invocation->{selection}
        ? { selection => $invocation->{selection} }
        : { reports   => 1, summary => $world->{env}{GITHUB_STEP_SUMMARY} }
    );
    _report( $result, $config, $world );
    return _concluded( $result, $config, $world );
}

sub _baseline ( $invocation, $world ) {
    my $config = $invocation->{config};
    my $result = Test::Mutation::Runner::run( $config, sub { }, { baseline_only => 1 } );
    say { $world->{out} } 'Baseline: ', _plural( scalar $result->tests->@*, 'test' );
    say { $world->{err} } $_->{test} for $result->baseline_failures->@*;
    return _concluded( $result, $config, $world );
}

sub _settings ( $invocation, $world ) {
    for my $setting ( Test::Mutation::Settings::rows()->@* ) {
        say { $world->{out} } _option_words($setting), '  ', $setting->help, ' (default: ', $setting->default_text, ')';
    }
    return 0;
}

sub _progress ( $errors, $in_place, $processors ) {
    my ( %counts, $total );
    my $done = 0;
    return sub ( $event, $data ) {
        if ( $event eq 'analyzed' ) {
            print {$errors} Test::Mutation::Host::describe($processors), "\n";
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
    my %wanted = map { $_ => 1 } $config->format->@*;
    print { $world->{out} } Test::Mutation::Report::Terminal::render( $result, color => 0 ) if $wanted{terminal};

    my @written;
    for my $format ( grep { $wanted{$_} } qw(json html) ) {
        my ( $name, $render ) = $FILE_REPORT{$format}->@*;
        my $directory = $config->report_dir;
        my $target    = File::Spec->rel2abs( $directory, $config->root );
        Test::Mutation::Tree::make($target);
        my $text = $render->( $result, high => $config->threshold_high, low => $config->threshold_low );
        _write( "$target/$name", "$directory/$name", '>', $text );
        push @written, "$directory/$name";
    }
    print { $world->{out} } 'Reports: ', join( ', ', @written ), "\n" if @written;
    _report_to_github( $result, $world, $config->root ) if $wanted{github};
    return;
}

sub _report_to_github ( $result, $world, $root ) {
    print { $world->{out} } Test::Mutation::Report::GitHub::annotations($result);
    my $path = $world->{env}{GITHUB_STEP_SUMMARY};
    return if !defined $path || !length $path;
    _write( File::Spec->rel2abs( $path, $root ), $path, '>>', Test::Mutation::Report::GitHub::summary($result) );
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
    my $floor  = $config->min_score;
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
    my @mutants =
        $invocation->{selection}
      ? $invocation->{selection}->mutants->@*
      : Test::Mutation::Runner::analyze( $invocation->{config} )->{mutants}->@*;
    say { $world->{out} } _heading($_), _suppression($_) for @mutants;
    say { $world->{out} } _plural( scalar @mutants, 'mutant' );
    return 0;
}

sub _suppression ($mutant) {
    my $reason = $mutant->suppression_reason;
    return
        !$mutant->suppressed ? q{}
      : defined $reason      ? "  (suppressed: $reason)"
      :                        '  (suppressed)';
}

sub _show ( $invocation, $world ) {
    my $analysis = Test::Mutation::Runner::analyze( $invocation->{config} );
    my $mutant   = Test::Mutation::Select::by_id( $analysis->{mutants}, $invocation->{operands}[0] );
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
    my $mutant   = Test::Mutation::Select::by_id( $analysis->{mutants}, $identifier );
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
    Test::Mutation::Select::outputs( $config, $world->{env}{GITHUB_STEP_SUMMARY} );
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
L<Test::Mutation::CLI::Arguments> reads the words, and L<Test::Mutation::Settings> reads the configuration file and builds the C<config>.
The help text lists the options of the table of the settings.
The function dies on an error that no check of the arguments foresees.

=head2 execute

    my $status = Test::Mutation::CLI::execute( $invocation, $world );

Carries a plan out and returns the exit status.
A plan to refuse prints its text.
A plan to act enters the directory, runs the command, and prints to the streams of the world.

=cut
