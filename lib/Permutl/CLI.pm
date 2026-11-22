package Permutl::CLI;
use v5.36;
use Cwd             ();
use File::Path      ();
use Getopt::Long    ();
use TOML::Tiny      ();
use Types::Standard qw(ArrayRef Int Slurpy Str);
use Type::Params    qw(signature_for);
use Permutl::Config;
use Permutl::Project;
use Permutl::Report::Html;
use Permutl::Report::Json;
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
        'jobs|j=i'     => \$cli{jobs},
        'min-score=f'  => \$cli{threshold_break},
        'format=s@'    => \$cli{formats},
        'report-dir=s' => \$cli{report_directory},
        'config=s'     => \my $file,
    ) or return;
    delete @cli{ grep { !defined $cli{$_} } keys %cli };
    my $processors = Permutl::Project::cpu_count();
    my $config     = eval {
        Permutl::Config->from_layers(
            root     => Cwd::getcwd(),
            defaults => { jobs => $processors > 1 ? $processors - 1 : 1 },
            file     => _configuration_file($file),
            cli      => \%cli,
        );
    };
    print {*STDERR} 'permutl: ', _first_line($@), "\n" if !$config;
    return $config;
}

sub _configuration_file ($named) {
    my $path = defined $named ? $named : 'permutl.toml';
    return {} if !defined $named && !-e $path;
    open my $handle, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "cannot close $path: $!\n";
    my ( $data, $error ) = TOML::Tiny::from_toml($text);
    die "$path: " . _first_line($error) . "\n" if !defined $data;
    return $data;
}

sub _first_line ($error) {
    my $message = ref $error && $error->can('message') ? $error->message : "$error";
    my ($line)  = split /\n/, $message;
    $line =~ s/ at \S+ line \d+[.]?\z//;
    return $line;
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
    _report( $result, $config );
    return _exit_status( $result, $config );
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
    return;
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
