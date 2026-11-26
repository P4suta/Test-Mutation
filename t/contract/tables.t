use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Fixture qw(copy_of);
use Gate;
use Library;
use Samples;
use Sources;
use Space;
use World;
use Test::Mutation::CLI;
use Test::Mutation::Commands;
use Test::Mutation::Config;
use Test::Mutation::Error;
use Test::Mutation::Exit;
use Test::Mutation::Interrupted;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Json;
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

subtest 'the comparison rejects a table that differs from the surface' => sub {
    is Space::differences( { a => 1, b => 2 }, { a => 1, b => 2 } ), [], 'equal maps';
    is Space::differences( { a => 1, b => 2 }, { a => 1, b => 3, c => 4 } ),
      [ 'b: the table says 2, the surface 3', 'c: the table says nothing, the surface 4' ],
      'a value that differs and a name that the table lacks';
    is Space::differences( { a => 1 }, {} ), ['a: the table says 1, the surface nothing'],
      'a name that the surface lacks';
};

subtest 'the configuration preserves the input spellings and the typed settings' => sub {

    # Moo keeps the declarations of the attributes with the maker of the constructor, and offers no other reader.
    my $specs   = Moo->_constructor_maker_for('Test::Mutation::Config')->all_attribute_specs;    ## no critic (Subroutines::ProtectPrivateSubs)
    my %surface = map { $_            => Space::attribute_facts( $specs->{$_} ) } keys $specs->%*;
    my %table   = map { $_->attribute => Space::attribute_text($_) } @settings;
    $table{specified} = 'value HashRef[Str] required has a value';
    is Space::differences( \%table, \%surface ), [], 'the origin map and every setting have their declared types';
    my $tree   = Space::tree( 'mutation.toml' => "jobs = 2\n" );
    my $config = Test::Mutation::Settings::of_call( { root => $tree, source_exclude => ['lib/Never.pm'] } );
    is $config->specified, { root => 'root', jobs => 'mutation.toml: jobs', 'source-exclude' => 'source_exclude' },
      'only supplied settings carry the spelling of the winning layer';
    Gate::checked( 'attributes', scalar( keys %surface ), at_least => 32 );
};

# The parser and the decoder of the file read the table, so the spaces S1 and S3 try every name on its surface.
# The table holds a flag for every setting, and the file holds every setting that does not find the file itself.
subtest 'the resolution of the settings builds every configuration' => sub {

    # A copy of the project holds no Git directory, so the walk reads the directories themselves.
    my @files = map { $_->@* } Library::modules('lib'), Library::modules('t'), Library::tests('t'),
      Library::tests('xt');
    my $built    = join q{}, 'Test::Mutation::Config', '->new';
    my @builders = grep { index( Sources::slurp($_), $built ) >= 0 } @files;
    is \@builders, ['lib/Test/Mutation/Settings.pm'],
      'one file of the library and the tests constructs a configuration';
    Gate::checked( 'files of the library and the tests', scalar @files, at_least => 150 );
};

subtest 'the settings table names a flag and a key for every setting' => sub {
    is scalar( Space::flags()->@* ),                                33,                'the settings with a flag';
    is [ map { $_->name } grep { !$_->offers('file') } @settings ], [qw(root config)], 'the settings outside the file';
};

subtest 'the commands table names every command and its line in the help' => sub {
    my $help = World::observe( ['--help'], cwd => $root )->{stdout};
    my ( $usage, $summaries, $options ) = $help =~ /\AUsage: (.*?)\n\nCommands:\n(.*?)\n\nOptions:\n(.*)\z/s
      or die "the help text has another shape\n";
    my @words = grep { $_->words->[0] !~ /\A-/ } @commands;
    is [ map { s/\A\s+//r } split /\n/, $usage ], [ map { $_->usage } @words ], 'the usage lines';
    my @columns = map { /\A(  \S+ +)\S/ ? length $1 : 0 } split /\n/, $summaries;
    is \@columns, [ ( $columns[0] ) x @words ], 'every command description starts in the same column';
    like dies { Test::Mutation::Commands::switches('extra') }, qr/Wrong number of parameters/,
      'the global switch table accepts no argument';
    is { map { /\A\s+(\S+)\s+(.+)\z/ ? ( $1 => $2 ) : () } split /\n/, $summaries },
      { map { $_->name => $_->summary } @words },
      'the summaries';
    my %line = map { /\A\s+(--[\w-]+)(?:, -\w)?\s{2,}(.+)\z/ ? ( $1 => $2 ) : () } split /\n/, $options;

    for my $switch ( Test::Mutation::Commands::switches()->@* ) {
        is $line{ $switch->{words}[0] }, $switch->{summary}, 'help describes the global option';
    }

    my ( %selects, %selected );
    for my $command (@commands) {
        for my $word ( $command->words->@* ) {
            $selects{$word} = $command->name;
            my $line = Space::line( { word => $word, command => $command }, [], $command->least );
            $selected{$word} = World::observe( $line, cwd => $root, run => 'cheap' )->{plan}{command};
        }
    }
    is \%selected, \%selects, 'each word selects its command';
    my ($default) = grep { $_->default } @commands;
    is [ map { World::observe( $_, cwd => $root, run => 'cheap' )->{plan}{command} } [], [ '--jobs', 2 ] ],
      [ $default->name, $default->name ], 'no word selects the default command';
    is [ map { $_->name } @commands ], [qw(run baseline list show exec merge mutators settings help)],
      'the nine commands';
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
        my ($mutant)     = map { $_->{mutants}->@* }
          values Test::Mutation::Report::Json::document( $result, high => 80, low => 60 )->{files}->%*;
        is {
            word       => $word,
            heading    => $heading,
            role       => !$tally->{valid}  ? 'outside' : $tally->{score} ? 'detected' : 'undetected',
            progress   => defined $progress ? 1 : 0,
            annotation => $annotation,
            cached     => Space::cache_keeps($name),
            schema     => $mutant->{status},
          },
          { map { $_ => $status->$_ } qw(word heading role progress annotation cached schema) }, "the facts of $name";
        is $mutant->{testMutation}{status}, $name,
          "the report file keeps the status $name beside the name of the schema";
        is $progress, $status->word, "the progress line counts $name with the same word" if defined $progress;
    }
    is scalar(@statuses), 8, 'the statuses';
};

subtest 'the exit table names every exit status of the command' => sub {
    my @signals = Test::Mutation::Exit::signals()->@*;
    my $failing = sub ( $failure, @line ) {
        no warnings 'redefine';
        local *Test::Mutation::Runner::analyze = $failure;
        return World::observe( \@line, cwd => $root )->{exit};
    };
    my $unreadable = sub { Test::Mutation::Error::raise( 'file-unreadable', path => 'lib/Calc.pm', reason => 'gone' ) };
    my ($mutant)   = World::observe( ['list'], cwd => $root )->{stdout} =~ /^([0-9a-f]{12})  /m;
    my %observed   = map { $_ => 1 } (
        ( map { World::observe( [ 'exec', $mutant, q{--}, "$root/$_" ], cwd => $root )->{exit} } 'lib', 'absent' ),
        ( map { World::observe( $_, cwd => $root )->{exit} } ['--version'], [ 'list', '--bogus' ] ),
        (
            map { Space::decided( Samples::result( $_->@* ), '--min-score', 50 )->{exit} } [ statuses => ['Killed'] ],
            [ statuses          => ['Survived'] ],
            [ statuses          => ['NoVerdict'] ],
            [ baseline_failures => [ { test => 't/a.t', output => q{}, errors => q{} } ] ]
        ),
        $failing->( $unreadable,              'list' ),
        $failing->( sub { die "a defect\n" }, 'list' ),
        $failing->( $unreadable,              'exec', 'zzzz', q{--}, 'true' ),
        ( map { Space::decided( Samples::result( statuses => ['Pending'], interrupted => $_ ) )->{exit} } @signals ),
    );
    is [ sort { $a <=> $b } keys %observed ], [ map { $_->code } @exits ],
      'the command returns every status of the table, and no other one';
    is [ map { $_->name } @exits ],
      [
        qw(success below-gate usage baseline-failed inconclusive environment internal exec-failed),
        qw(command-not-runnable command-not-found hangup interrupt quit pipe termination)
      ],
      'the names';
    my %meaning  = map { $_->code => $_->meaning } @exits;
    my %distinct = reverse %meaning;
    is scalar( keys %distinct ), scalar @exits, 'each status has a meaning of its own';

    for my $signal (@signals) {
        my $code = Test::Mutation::Interrupted->new( signal => $signal )->exit_status;
        like $meaning{$code}, qr/\b$signal\b/, "the meaning of status $code names the signal $signal";
    }
    is \@signals, [qw(HUP INT QUIT PIPE TERM)], 'the signals that have a status';
};

done_testing;
