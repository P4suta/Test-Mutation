package Permutl::CLI;
use v5.36;
use Cwd             ();
use File::Path      ();
use Getopt::Long    ();
use Types::Standard qw(ArrayRef Int Slurpy Str);
use Type::Params    qw(signature_for);
use Permutl::Config;
use Permutl::Interrupted;
use Permutl::Merge;
use Permutl::Project;
use Permutl::Report::GitHub;
use Permutl::Report::Html;
use Permutl::Report::Json;
use Permutl::Report::Patch;
use Permutl::Report::Progress;
use Permutl::Report::Terminal;
use Permutl::Runner;

our $VERSION = '0.001';

my %COMMAND = ( run => \&_run, list => \&_list, show => \&_show, exec => \&_exec, merge => \&_merge );

signature_for main => ( positional => [ Slurpy [ ArrayRef [Str] ] ], returns => Int );

my $HELP = <<'TEXT';
Usage: permutl [run] [options]
       permutl list [options]
       permutl show ID [options]
       permutl exec ID -- COMMAND [ARGUMENT...]
       permutl merge FILE... [options]

Commands:
  run     Measure how many mutants the tests detect (the default)
  list    Print the mutants without running a test
  show    Print one mutant as a unified diff
  exec    Run a command with one mutant active
  merge   Report one run from the mutation.json of every part of --shard

Options:
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
  --keep-work           Keep the work directory after the run
  --mutant ID           Run the named mutant; repeatable
  --since REVISION      Cover the lines changed since a Git revision
  --shard K/N           Cover part K of N equal parts of the mutants
  --no-equivalence      Keep the mutants that compile to the original code
  --cache               Reuse the results of an earlier run where the inputs are unchanged
  --config FILE         Configuration file to read in place of permutl.toml
  --version             Print the version
  --help                Print this text
TEXT

sub main ($list) {
    my @arguments = $list->@*;
    my $first     = @arguments ? $arguments[0] : q{};
    if ( $first eq '--version' ) {
        say "permutl $VERSION";
        return 0;
    }
    if ( $first eq '--help' || $first eq '-h' ) {
        print $HELP;
        return 0;
    }
    my $command = $COMMAND{$first} ? shift @arguments : 'run';
    my $status  = eval { $COMMAND{$command}->(@arguments) };
    return $status if defined $status;
    my $error = $@;
    if ( ref $error && $error->isa('Permutl::Interrupted') ) {
        print {*STDERR} 'permutl: interrupted by SIG', $error->signal, "\n";
        return $error->exit_status;
    }
    print {*STDERR} 'permutl: ', _first_line($error), "\n";
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
);

sub _config ($arguments) {
    my %cli;
    my $parser = Getopt::Long::Parser->new( config => [qw(bundling no_ignore_case)] );
    $parser->getoptionsfromarray(
        $arguments,
        ( map { $_ => \$cli{ $SETTING_OF_OPTION{$_} } } keys %SETTING_OF_OPTION ),
        'config=s' => \my $file,
    ) or return;
    delete @cli{ grep { !defined $cli{$_} } keys %cli };
    my $processors = Permutl::Project::cpu_count();
    my $config     = eval {
        Permutl::Config->from_layers(
            root     => Cwd::getcwd(),
            defaults => {
                jobs    => $processors > 1 ? $processors - 1 : 1,
                formats => [ qw(terminal json html), _inside_github_actions() ? 'github' : () ],
            },
            file => _configuration_file($file),
            cli  => \%cli,
        );
    };
    print {*STDERR} 'permutl: ', _first_line($@), "\n" if !$config;
    return $config;
}

sub _inside_github_actions () {
    my $value = $ENV{GITHUB_ACTIONS};
    return defined $value && $value eq 'true' ? 1 : 0;
}

sub _configuration_file ($named) {
    my $path = defined $named ? $named : 'permutl.toml';
    return {} if !defined $named && !-e $path;
    return Permutl::Config::read_file($path);
}

sub _first_line ($error) {
    my $message = ref $error && $error->can('message') ? $error->message : "$error";
    my ($line)  = split /\n/, $message;
    $line =~ s/ at \S+ line \d+[.]?\z//;
    return $line;
}

sub _run (@arguments) {
    my $config = _config( \@arguments ) or return 2;
    return _usage("unexpected argument $arguments[0]") if @arguments;
    my $terminal = -t *STDERR ? 1 : 0;                                      ## no critic (InputOutput::ProhibitInteractiveTest)
    my $result   = Permutl::Runner::run( $config, _progress($terminal) );
    _report( $result, $config );
    print {*STDERR} 'permutl: interrupted by SIG', $result->interrupted, "\n" if defined $result->interrupted;
    return _exit_status( $result, $config );
}

sub _progress ($in_place) {
    my ( %counts, $total );
    my $done = 0;
    return sub ( $event, $data ) {
        if ( $event eq 'analyzed' ) {
            $total = $data->{mutants};
            printf {*STDERR} "%s in %s, %s\n", _plural( $total, 'mutant' ), _plural( $data->{files}, 'file' ),
              _plural( $data->{tests}, 'test' );
        }
        elsif ( $event eq 'baseline' ) {
            printf {*STDERR} "The unmodified run passed: %s, %s\n", _plural( $data->{tests}, 'test' ),
              _plural( $data->{jobs}, 'job' );
        }
        elsif ( $event eq 'mutant' ) {
            $counts{ $data->{status} }++;
            $done++;
            my $line = Permutl::Report::Progress::line( $done, $total, \%counts );
            if ($in_place) {
                print {*STDERR} "\r$line", $done == $total ? "\n" : q{};
            }
            elsif ( Permutl::Report::Progress::due( $done, $total ) ) {
                print {*STDERR} "$line\n";
            }
        }
        return;
    };
}

my %FILE_REPORT = (
    json => [ 'mutation.json', \&Permutl::Report::Json::render ],
    html => [ 'mutation.html', \&Permutl::Report::Html::render ],
);

sub _report ( $result, $config ) {
    my %wanted = map { $_ => 1 } $config->formats->@*;
    print Permutl::Report::Terminal::render( $result, color => 0 ) if $wanted{terminal};

    my @written;
    for my $format ( grep { $wanted{$_} } qw(json html) ) {
        my ( $name, $render ) = $FILE_REPORT{$format}->@*;
        my $directory = $config->report_directory;
        File::Path::make_path( $config->root . "/$directory" );
        my $text = $render->( $result, high => $config->threshold_high, low => $config->threshold_low );
        open my $handle, '>:encoding(UTF-8)', $config->root . "/$directory/$name"
          or die "cannot write $directory/$name: $!\n";
        print {$handle} $text or die "cannot write $directory/$name: $!\n";
        close $handle         or die "cannot close $directory/$name: $!\n";
        push @written, "$directory/$name";
    }
    print 'Reports: ', join( ', ', @written ), "\n" if @written;
    _report_to_github($result) if $wanted{github};
    return;
}

sub _report_to_github ($result) {
    print Permutl::Report::GitHub::annotations($result);
    my $path = $ENV{GITHUB_STEP_SUMMARY};
    return if !defined $path || !length $path;
    open my $handle, '>>:encoding(UTF-8)', $path or die "cannot write $path: $!\n";
    print {$handle} Permutl::Report::GitHub::summary($result) or die "cannot write $path: $!\n";
    close $handle                                             or die "cannot close $path: $!\n";
    return;
}

sub _exit_status ( $result, $config ) {
    return Permutl::Interrupted->new( signal => $result->interrupted )->exit_status if defined $result->interrupted;
    return 3                                                                        if $result->baseline_failures->@*;
    return 4                                                                        if !$result->conclusive;
    my $score = $result->tally->{score};
    my $floor = $config->threshold_break;
    return 1 if defined $floor && defined $score && $score < $floor;
    return 0;
}

sub _heading ($mutant) {
    my $place = sprintf '%s:%d:%d', $mutant->path, $mutant->from->@*;
    return join q{  }, $mutant->id, $place, $mutant->mutator, $mutant->description;
}

sub _list (@arguments) {
    my $config  = _config( \@arguments ) or return 2;
    my @mutants = Permutl::Runner::analyze($config)->{mutants}->@*;
    say _heading($_), $_->suppressed ? '  (suppressed)' : q{} for @mutants;
    say _plural( scalar @mutants, 'mutant' );
    return 0;
}

sub _usage ($message) {
    print {*STDERR} "permutl: $message\n";
    return 2;
}

sub _find ( $analysis, $identifier ) {
    my @matches = grep { index( $_->id, $identifier ) == 0 } $analysis->{mutants}->@*;
    return $matches[0] if @matches == 1;
    die( ( @matches ? 'more than one mutant has' : 'no mutant has' ) . " the identifier $identifier\n" );
}

sub _show (@arguments) {
    my $config = _config( \@arguments ) or return 2;
    return _usage('show needs a mutant identifier') if !@arguments;
    my $analysis = Permutl::Runner::analyze($config);
    my $mutant   = eval { _find( $analysis, $arguments[0] ) } or return _usage( _first_line($@) );
    say _heading($mutant);
    print Permutl::Report::Patch::render( text => $analysis->{sources}{ $mutant->path }->text, mutant => $mutant );
    return 0;
}

sub _exec (@arguments) {
    my $config = _config( \@arguments ) or return 2;
    my ( $identifier, @command ) = @arguments;
    return _usage('exec needs a mutant identifier and a command') if !@command;
    my $analysis = Permutl::Runner::analyze($config);
    my $mutant   = eval { _find( $analysis, $identifier ) } or return _usage( _first_line($@) );
    return Permutl::Runner::run_command( $config, $analysis->{sources}{ $mutant->path }, $mutant, \@command );
}

sub _read_report ($path) {
    open my $handle, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
    local $/ = undef;
    my $text = readline $handle;
    close $handle or die "cannot close $path: $!\n";
    my $result = eval { Permutl::Report::Json::parse( defined $text ? $text : q{} ) };
    return $result if $result;
    die "$path: " . _first_line($@) . "\n";
}

sub _merge (@arguments) {
    my $config = _config( \@arguments ) or return 2;
    return _usage('merge needs the report of every part') if !@arguments;
    my $result = eval {
        Permutl::Merge::merge( [ map { { name => $_, result => _read_report($_) } } @arguments ] );
    }
      or return _usage( _first_line($@) );
    _report( $result, $config );
    return _exit_status( $result, $config );
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
