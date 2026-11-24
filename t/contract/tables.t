use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Fixture qw(copy_of);
use Gate;
use Samples;
use Space;
use World;
use Test::Mutation::CLI;
use Test::Mutation::Commands;
use Test::Mutation::Config;
use Test::Mutation::Exit;
use Test::Mutation::Interrupted;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Progress;
use Test::Mutation::Report::Terminal;
use Test::Mutation::Score;
use Test::Mutation::Settings;
use Test::Mutation::Status;

# The tables describe the surface of the command as it stands.
# Each check reads the real surface and requires it to equal the table, so a table that drifts from the code fails here.

my $root     = copy_of('calc');
my @settings = Test::Mutation::Settings::rows()->@*;
my @commands = Test::Mutation::Commands::rows()->@*;
my @statuses = Test::Mutation::Status::rows()->@*;
my @exits    = Test::Mutation::Exit::rows()->@*;

sub slurp ($path) {
    open my $handle, '<:encoding(UTF-8)', $path or die "read $path: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return $text;
}

subtest 'the comparison rejects a table that differs from the surface' => sub {
    is Space::differences( { a => 1, b => 2 }, { a => 1, b => 2 } ), [], 'equal maps';
    is Space::differences( { a => 1, b => 2 }, { a => 1, b => 3, c => 4 } ),
      [ 'b: the table says 2, the surface 3', 'c: the table says nothing, the surface 4' ],
      'a value that differs and a name that the table lacks';
    is Space::differences( { a => 1 }, {} ), ['a: the table says 1, the surface nothing'],
      'a name that the surface lacks';
};

subtest 'the settings table names every attribute of the configuration' => sub {

    # Moo keeps the declarations of the attributes with the maker of the constructor, and offers no other reader.
    my $specs   = Moo->_constructor_maker_for('Test::Mutation::Config')->all_attribute_specs;    ## no critic (Subroutines::ProtectPrivateSubs)
    my %surface = map { $_            => Space::attribute_facts( $specs->{$_} ) } keys $specs->%*;
    my %table   = map { $_->attribute => Space::attribute_text( $_, $specs->{ $_->attribute }{required} ) }
      grep { defined $_->attribute } @settings;
    is Space::differences( \%table, \%surface ), [], 'the kind, the type, and the default of every attribute';
    Gate::checked( 'attributes', scalar( keys %surface ), at_least => 29 );
};

subtest 'the settings table names every option that the parser takes' => sub {
    for my $command (@commands) {
        my $name = $command->name;
        my %surface =
          map { $_ => 1 } Space::option_specs( [ $command->words->[0], ('x') x $command->least ], cwd => $root )->@*;
        my %table = map { Space::option_spec($_) => 1 } grep { Space::accepts( $_, $name ) } Space::flags()->@*;
        is Space::differences( \%table, \%surface ), [], "the options of $name";
    }
    is scalar( Space::flags()->@* ), 22, 'the settings with a flag';
};

subtest 'the settings table names every key that the configuration file takes' => sub {
    my %surface = Space::file_keys( slurp('lib/Test/Mutation/Config.pm') )->%*;
    my %table   = map { join( q{.}, $_->key->@* ) => $_->attribute } grep { $_->key } @settings;
    is Space::differences( \%table, \%surface ), [], 'the section, the key, and the attribute of every key';
    Gate::checked( 'keys of the configuration file', scalar( keys %surface ), at_least => 21 );
};

subtest 'the commands table names every command and its line in the help' => sub {
    my $help = World::observe( ['--help'], cwd => $root )->{stdout};
    my ( $usage, $summaries, $options ) = $help =~ /\AUsage: (.*?)\n\nCommands:\n(.*?)\n\nOptions:\n(.*)\z/s
      or die "the help text has another shape\n";
    my @words = grep { $_->words->[0] !~ /\A-/ } @commands;
    is [ map { s/\A\s+//r } split /\n/, $usage ], [ map { $_->usage } @words ], 'the usage lines';
    is { map { /\A\s+(\S+)\s+(.+)\z/ ? ( $1 => $2 ) : () } split /\n/, $summaries },
      { map { $_->name => $_->summary } @words },
      'the summaries';
    my %line     = map  { /\A\s+(--[\w-]+)\s{2,}(.+)\z/ ? ( $1 => $2 ) : () } split /\n/, $options;
    my @optional = grep { $_->words->[0] =~ /\A-/ } @commands;
    is {
        map { $_->name => $line{ $_->words->[0] } } @optional
    }, { map { $_->name => $_->summary } @optional }, 'the lines of the commands that an option selects';

    my ( %selects, %selected );
    for my $command (@commands) {
        for my $word ( $command->words->@* ) {
            $selects{$word} = $command->name;
            my $line = [ $word, ('x') x $command->least ];
            $selected{$word} = World::observe( $line, cwd => $root, run => 'cheap' )->{plan}{command};
        }
    }
    is \%selected, \%selects, 'each word selects its command';
    my ($default) = grep { $_->default } @commands;
    is [ map { World::observe( $_, cwd => $root, run => 'cheap' )->{plan}{command} } [], [ '--jobs', 2 ] ],
      [ $default->name, $default->name ], 'no word selects the default command';
    is scalar(@commands), 8, 'the commands';
};

subtest 'the status table names every status and what each report does with it' => sub {
    is [ sort keys Test::Mutation::Score::tally( [] )->{counts}->%* ], [ sort map { $_->name } @statuses ], 'the names';
    for my $status (@statuses) {
        my $name         = $status->name;
        my $result       = Samples::result( statuses => [$name] );
        my $tally        = Test::Mutation::Score::tally( [$name] );
        my $report       = Test::Mutation::Report::Terminal::render( $result, color => 0 );
        my ($word)       = $report                                                        =~ /\A1 mutant: 1 ([^\n]+)\n/;
        my ($heading)    = $report                                                        =~ /^(\S[^\n]*) [(]1[)]$/m;
        my ($progress)   = Test::Mutation::Report::Progress::line( 1, 1, { $name => 1 } ) =~ /\A\[1\/1\] 1 (.+)\z/;
        my ($annotation) = Test::Mutation::Report::GitHub::annotations($result)           =~ /\A::(\w+) /;
        is {
            word       => $word,
            heading    => $heading,
            role       => !$tally->{valid}  ? 'outside' : $tally->{score} ? 'detected' : 'undetected',
            progress   => defined $progress ? 1 : 0,
            annotation => $annotation,
            cached     => Space::cache_keeps($name),
          },
          { map { $_ => $status->$_ } qw(word heading role progress annotation cached) }, "the facts of $name";
        is $progress, $status->word, "the progress line counts $name with the same word" if defined $progress;
    }
    is scalar(@statuses), 8, 'the statuses';
};

subtest 'the exit table names every exit status of the command' => sub {
    my %observed = map { $_ => 1 } (
        ( map { World::observe( $_, cwd => $root )->{exit} } ['--version'], [ 'list', '--bogus' ] ),
        (
            map { Space::decided( Samples::result( $_->@* ), '--min-score', 50 )->{exit} } [ statuses => ['Killed'] ],
            [ statuses          => ['Survived'] ],
            [ statuses          => ['RuntimeError'] ],
            [ baseline_failures => [ { test => 't/a.t', output => q{}, errors => q{} } ] ]
        ),
        ( map { Test::Mutation::Interrupted->new( signal => $_ )->exit_status } qw(HUP INT TERM) ),
    );
    is [ sort { $a <=> $b } keys %observed ], [ map { $_->code } @exits ], 'the codes, in rising order';
    is [ map { $_->name } @exits ],
      [qw(success below-gate usage baseline-failed inconclusive hangup interrupt termination)],
      'the names';
    my %meaning  = map { $_->code => $_->meaning } @exits;
    my %distinct = reverse %meaning;
    is scalar( keys %distinct ), scalar @exits, 'each status has a meaning of its own';
    for my $signal (qw(HUP INT TERM)) {
        my $code = Test::Mutation::Interrupted->new( signal => $signal )->exit_status;
        like $meaning{$code}, qr/\b$signal\b/, "the meaning of status $code names the signal $signal";
    }
};

done_testing;
