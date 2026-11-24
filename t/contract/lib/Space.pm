package Space;
use v5.36;
use Cwd          ();
use File::Temp   ();
use Getopt::Long ();
use Fixture      ();
use Samples;
use World;
use Test::Mutation ();
use Test::Mutation::Cache;
use Test::Mutation::Commands;
use Test::Mutation::Report::Json;
use Test::Mutation::Result;
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Status;
use Test2::API ();

# The spaces of cases come from the tables alone, so a new row brings its cases with it.
# A table builds its rows on every call, so the spaces read each table once.
my $SETTINGS = Test::Mutation::Settings::rows();
my $COMMANDS = Test::Mutation::Commands::rows();

# What differs between a table and the surface it describes, both as maps from a name to a text.
sub differences ( $table, $surface ) {
    my @differences;
    my %names = ( $table->%*, $surface->%* );
    for my $name ( sort keys %names ) {
        my ( $said, $found ) = map { exists $_->{$name} ? $_->{$name} : 'nothing' } $table, $surface;
        push @differences, "$name: the table says $said, the surface $found" if $said ne $found;
    }
    return \@differences;
}

sub default_text ( $kind, $value ) {
    return join q{ }, $value->@* if $kind eq 'list';
    return $value ? 'on' : 'off' if $kind eq 'flag';
    return q{}                   if !defined $value;
    return $value eq $^X ? 'the running interpreter' : "$value";
}

# The kind, the type of one value, and the default of an attribute, read from what Moo keeps about it.
sub attribute_facts ($spec) {
    my $isa    = $spec->{isa}->display_name;
    my $kind   = $isa =~ /\AArrayRef\[/ ? 'list' : $isa eq 'Bool' ? 'flag' : 'value';
    my $single = $isa =~ s/\A(?:Maybe|ArrayRef)\[(.*)\]\z/$1/r;
    return "$kind $single" if $spec->{required};
    my $default = $spec->{default};
    return join q{ }, $kind, $single, default_text( $kind, ref $default eq 'CODE' ? $default->() : $default );
}

sub attribute_text ( $setting, $required ) {
    return join q{ }, $setting->kind, Samples::type( $setting->type )->{isa}, $required ? () : $setting->default_text;
}

# The option specifications that a plan hands to the option parser.
sub option_specs ( $argv, %fact ) {
    my @specs;

    # The parser class loads on its first object, and a name taken before that would hide the method.
    my $parse = Getopt::Long::Parser->new->can('getoptionsfromarray');
    no warnings 'redefine';
    local *Getopt::Long::Parser::getoptionsfromarray = sub ( $parser, $arguments, @pairs ) {
        push @specs, grep { !ref } @pairs;
        return $parse->( $parser, $arguments, @pairs );
    };
    World::observe( $argv, %fact, run => 'cheap' );
    return \@specs;
}

# The option specification that a row of the settings table describes.
sub option_spec ($setting) {
    my $names = substr $setting->flag, 2;
    $names .= q{|} . substr $setting->short, 1 if defined $setting->short;
    return $names . ( $setting->negatable ? q{!} : q{} ) if $setting->kind eq 'flag';
    return $names . q{=} . Samples::type( $setting->type )->{letter} . ( $setting->kind eq 'list' ? q{@} : q{} );
}

# The name of the attribute where it differs from the name of the flag, as a name of another surface.
sub foreign_name ($setting) {
    my $attribute = $setting->attribute;
    return defined $attribute && $attribute ne substr( $setting->flag, 2 ) ? $attribute : undef;
}

sub accepts ( $setting, $command ) {
    return scalar grep { $_ eq $command } $setting->commands->@*;
}

# The sections and keys of the configuration file with their attributes, read from the table in the source.
sub file_keys ($source) {
    my ($table) = $source =~ /^my %FILE_KEYS = [(]\n(.*?)^[)];/ms
      or die "the configuration holds no table of file keys\n";
    my %keys;
    while ( $table =~ /(\w+|q\{\})\s*=>\s*\{(.*?)\}/gs ) {
        my ( $section, $pairs ) = ( $1 eq 'q{}' ? q{} : $1, $2 );
        $keys{"$section.$1"} = $2 while $pairs =~ /'?([\w-]+)'?\s*=>\s*'(\w+)'/g;
    }
    return \%keys;
}

sub cache_keeps ($status) {
    my $file   = File::Temp->new;
    my %record = (
        inputs    => q{},
        status    => $status,
        reason    => undef,
        by        => undef,
        tests_run => 0,
        duration  => 0,
        code      => undef
    );
    return Test::Mutation::Cache::save( $file->filename, { record => \%record } );
}

my $SCRATCH = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
Fixture::write_file( "$SCRATCH/quiet.toml", "[report]\nformats = []\n" );

# The exit status that `mutation run` decides for a result, with no report and no test.
sub decided ( $result, @arguments ) {
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub { return $result };
    return World::observe( [ 'run', '--config', "$SCRATCH/quiet.toml", @arguments ], cwd => $SCRATCH );
}

sub scratch () {
    return $SCRATCH;
}

# What `mutation merge` decides for the two parts of a result, as its exit status.
sub merged ( $result, @arguments ) {
    my @entries = $result->entries->@*;
    for my $part ( 1, 2 ) {
        my $piece = Test::Mutation::Result->new(
            (
                map { $_ => $result->$_ }
                  qw(root sources tests problems warnings baseline_failures jobs parallel_safe started finished)
            ),
            entries   => [ @entries[ grep { $_ % 2 == $part - 1 } 0 .. $#entries ] ],
            shard     => "$part/2",
            inventory => { mutants => scalar @entries, digest => 'a' x 64 },
        );
        Fixture::write_file( "$SCRATCH/part$part.json",
            Test::Mutation::Report::Json::render( $piece, high => 80, low => 60 ) );
    }
    my @line = ( 'merge', 'part1.json', 'part2.json', '--config', 'quiet.toml', @arguments );
    return World::observe( \@line, cwd => $SCRATCH )->{exit};
}

# What `mutation_score_ok` decides for a result: true when the assertion passes.
sub asserted ( $result, $root, @arguments ) {
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub { return $result };
    my $passed;
    Test2::API::intercept( sub { $passed = Test::Mutation::mutation_score_ok( root => $root, @arguments ) } );
    return $passed ? 1 : 0;
}

# S5, the outcomes: the statuses that a result holds, each absent or present, and a few results with two of one status.
sub status_sets () {
    my @names = map { $_->name } Test::Mutation::Status::rows()->@*;
    my @sets  = ( [] );
    for my $name (@names) {
        push @sets, map { [ $_->@*, $name ] } @sets;
    }
    return [ @sets, [qw(Killed Killed Survived)], [qw(Killed Survived Survived)] ];
}

# The command lines that select a command: each of its words, and no word at all for the default command.
sub forms () {
    my @forms;
    for my $command ( $COMMANDS->@* ) {
        push @forms, map { { command => $command, word => $_, label => $command->name } }
          grep { !/\A-/ } $command->words->@*;
        push @forms, { command => $command, word => undef, label => 'default' } if $command->default;
    }
    return \@forms;
}

# A command line: the word, the early options, the first operand, the late options, and the other operands.
# The command of `exec` stands behind two dashes.
sub line ( $form, $early, $count, $late = [] ) {
    my $name = $form->{command}->name;
    my ( $first, @others ) = Samples::operands( $name, $count )->@*;
    unshift @others, q{--} if $name eq 'exec' && @others;
    return [
        ( defined $form->{word} ? $form->{word} : () ), $early->@*, ( defined $first ? $first : () ),
        $late->@*,                                      @others
    ];
}

sub samples ($setting) {
    my $type = Samples::type( $setting->type );

    # The directory of the project must exist, so its sample is the directory of the world.
    return { $type->%*, valid => [ q{.}, q{.} ] } if $setting->name eq 'root';
    return $type;
}

sub flags () {
    return [ grep { defined $_->flag } $SETTINGS->@* ];
}

# The proper prefixes of a flag that are no flag themselves.
sub prefixes ($setting) {
    my %flag = map { $_->flag => 1 } flags()->@*;
    my $name = substr $setting->flag, 2;
    return [ grep { !$flag{$_} } map { q{--} . substr $name, 0, $_ } 1 .. length($name) - 1 ];
}

my @VARIANTS = qw(valid invalid missing repeated equals short negated prefix typo after-operand after-dashes);

sub variants () {
    return [@VARIANTS];
}

# What the cases of one setting on one form of a command share.
sub _written ( $form, $setting ) {
    my $command = $form->{command};
    my $sample  = samples($setting);
    my $kind    = $setting->kind;
    my @valid   = $sample->{valid}->@*;
    my $least   = $command->least;
    return {
        form    => $form,
        command => $command,
        setting => $setting,
        flag    => $setting->flag,
        kind    => $kind,
        valued  => $kind ne 'flag',
        valid   => \@valid,
        invalid => $sample->{invalid},
        value   => [ $kind eq 'flag' ? () : $valid[0] ],
        single  => $kind eq 'flag'                     ? 1        : $valid[0],
        ok      => accepts( $setting, $command->name ) ? 'accept' : 'refuse',
        least   => $least,
        early   => sub (@options) { line( $form, \@options, $least ) },
    };
}

# The ways to write a flag that every setting has.
sub _plain_cases ($written) {
    my ( $flag, $kind, $ok, $single, $early ) = $written->@{qw(flag kind ok single early)};
    my @valid   = $written->{valid}->@*;
    my @value   = $written->{value}->@*;
    my $negated = '--no-' . substr $flag, 2;
    my $typo    = $flag =~ s/.\z/z/r;
    my $twice   = $kind eq 'list' ? "$valid[0] $valid[-1]" : $kind eq 'flag' ? 1 : $valid[-1];
    return (
        [ 'valid',    $early->( $flag, @value ), $ok, $flag, $single ],
        [ 'repeated', $early->( $flag, @value, $flag, $kind eq 'flag' ? () : $valid[-1] ), $ok, $flag, $twice ],
        [
            'equals',
            $early->( $kind eq 'flag' ? "$flag=1" : "$flag=$valid[0]" ),
            $kind eq 'flag' ? 'refuse' : $ok,
            $flag, $single
        ],
        [ 'negated', $early->($negated), $written->{setting}->negatable ? $ok : 'refuse', $negated, 0 ],
        [ 'typo',    $early->( $typo, @value ), 'refuse', $typo ],
    );
}

# The ways to write a flag that some settings and some commands lack.
sub _other_cases ($written) {
    my ( $form, $setting, $flag, $ok, $single, $early, $least ) =
      $written->@{qw(form setting flag ok single early least)};
    my @value = $written->{value}->@*;
    my @cases = map { [ 'prefix', $early->( $_, @value ), 'refuse', $_ ] } prefixes($setting)->@*;
    push @cases, [ 'invalid', $early->( $flag, $written->{invalid}[0] ), 'refuse', $flag ]
      if $written->{valued} && $written->{invalid}->@*;
    push @cases, [ 'missing', line( $form, [], $least, [$flag] ), 'refuse', $flag ] if $written->{valued};
    push @cases, [ 'short', $early->( $setting->short, @value ), $ok, $setting->short, $single ]
      if defined $setting->short;
    push @cases, [ 'after-operand', line( $form, [], $least, [ $flag, @value ] ), $ok, $flag, $single ] if $least;
    return @cases;
}

# The words behind two dashes are operands, so the settings stay and the count of the operands decides.
sub _dashed_case ($written) {
    my ( $form, $command, $flag, $least ) = $written->@{qw(form command flag least)};
    my @behind = ( $flag, $written->{value}->@* );
    my $exec   = $command->name eq 'exec';
    my $fits   = $exec || !defined $command->most || $least + @behind <= $command->most;
    my @before = $exec ? ( $form->{word}, Samples::operands( 'exec', 1 )->@* ) : line( $form, [], $least )->@*;
    return [ 'after-dashes', [ @before, q{--}, @behind ], $fits ? 'accept' : 'refuse', $flag ];
}

# The cases of one setting on one form of a command, each with what the tables call for.
# `breaks` names the invariant that an accepted line breaks when the tables call for a refusal.
sub _cases ( $form, $setting ) {
    my $written = _written( $form, $setting );
    my %breaks  = ( prefix => 'no-abbrev', typo => 'unknown', 'after-dashes' => 'stray' );
    return map {
        {
            variant => $_->[0],
            argv    => $_->[1],
            expect  => $_->[2],
            typed   => $_->[3],
            value   => $_->[4],
            setting => $setting,
            form    => $form,
            breaks  => $breaks{ $_->[0] } || 'exit-table',
        }
    } _plain_cases($written), _other_cases($written), _dashed_case($written);
}

# S1: each form of a command, each setting with a flag, and each way to write the flag.
sub arguments () {
    my @cases;
    for my $form ( forms()->@* ) {
        push @cases, map { _cases( $form, $_ ) } flags()->@*;
    }
    return \@cases;
}

# The number of cases that the tables call for, counted another way than the cases are built.
sub arguments_count () {
    my @flags  = flags()->@*;
    my $forms  = scalar forms()->@*;
    my $behind = scalar grep { $_->{command}->least } forms()->@*;
    my $each   = 0;
    for my $setting (@flags) {
        my $valued = $setting->kind ne 'flag';
        $each += 6;    # valid, repeated, equals, negated, typo, after-dashes
        $each += 1 if $valued && samples($setting)->{invalid}->@*;
        $each += 1 if $valued;
        $each += 1 if defined $setting->short;
        $each += scalar prefixes($setting)->@*;
    }
    return $forms * $each + $behind * @flags;
}

# S3, the surfaces: what one sample of a setting looks like on the command line, in the file, and in a call.
# A surface that lacks the setting, or that has no way to say the value, gives nothing.
sub on_surface ( $setting, $surface, $value ) {
    my $type = samples($setting);
    my $kind = $setting->kind;
    if ( $surface eq 'flag' ) {
        my $flag = $setting->flag;
        return                   if !defined $flag;
        return [ $flag, $value ] if $kind ne 'flag';
        return ["$flag=$value"]  if $value !~ /\A[01]\z/;
        return [$flag]           if $value;
        return $setting->negatable ? [ '--no-' . substr $flag, 2 ] : ();
    }
    if ( $surface eq 'file' ) {
        my $key  = $setting->key or return;
        my $text = Samples::toml( $type, $value );
        return
            ( length $key->[0] ? "[$key->[0]]\n" : q{} )
          . "$key->[1] = "
          . ( $kind eq 'list' ? "[$text]" : $text ) . "\n";
    }
    return if !defined $setting->attribute;
    return [ $setting->attribute, $kind eq 'list' ? [$value] : $value ];
}

sub surfaces () {
    return [qw(flag file library)];
}

# The cases of S3: each setting, each sample of its type, and each surface that can say it.
sub settings () {
    my @cases;
    for my $setting ( $SETTINGS->@* ) {
        my $type = samples($setting);
        for my $expect (qw(valid invalid)) {
            for my $sample ( $type->{$expect}->@* ) {
                for my $surface ( surfaces()->@* ) {
                    my $said = on_surface( $setting, $surface, $sample );
                    push @cases,
                      { setting => $setting, sample => $sample, expect => $expect, surface => $surface, said => $said }
                      if defined $said;
                }
            }
        }
    }
    return \@cases;
}

# The number of those cases, counted from the sizes of the tables.
sub settings_count () {
    my $count = 0;
    for my $setting ( $SETTINGS->@* ) {
        my $type    = samples($setting);
        my $samples = $type->{valid}->@* + $type->{invalid}->@*;
        $count += $samples * grep { defined } $setting->flag, $setting->key, $setting->attribute;

        # A flag that the command line cannot negate has no way to say false.
        $count-- if $setting->kind eq 'flag' && defined $setting->flag && !$setting->negatable;
    }
    return $count;
}

# The configuration that a call of the library builds, or nothing when the call refuses its arguments.
sub library ( $root, @arguments ) {
    my $config;
    no warnings 'redefine';
    local *Test::Mutation::Runner::analyze = sub ($given) { $config = $given; return { mutants => [] } };
    my $returned = eval { Test::Mutation::mutants( root => $root, @arguments ); 1 };
    return $returned ? $config : undef;
}

# The value of an attribute as the text of a sample.
sub value_text ( $setting, $config ) {
    my $attribute = $setting->attribute;
    my $value     = $config->$attribute;
    return join q{ }, $value->@* if ref $value;
    return $value ? 1 : 0 if $setting->kind eq 'flag';
    return defined $value ? "$value" : q{};
}

# S4, the selectors: each kind of selector, whether it matches, and where the user wrote it.
# `setting` names the row of the settings table that says where a user may write the selector.
# `default` lists the states that a project reaches with no selector at all.
my @SELECTORS = (
    {
        kind      => 'source',
        setting   => 'source_include',
        command   => 'list',
        default   => [qw(matches nothing)],
        matches   => 'lib/Tiny.pm',
        nothing   => 'lib/Nothing*.pm',
        malformed => q{}
    },
    {
        kind      => 'exclude',
        setting   => 'source_exclude',
        command   => 'list',
        default   => [],
        matches   => 'lib/Other.pm',
        nothing   => 'lib/Nothing*.pm',
        malformed => q{}
    },
    {
        kind      => 'test',
        setting   => 'test_include',
        command   => 'run',
        default   => [qw(matches nothing)],
        matches   => 't/tiny.t',
        nothing   => 't/nothing*.t',
        malformed => q{}
    },
    {
        kind      => 'mutant',
        setting   => 'only',
        command   => 'list',
        default   => [],
        matches   => 'the first identifier',
        nothing   => 'ffffffffffff',
        malformed => 'zz'
    },
    {
        kind      => 'mutator',
        setting   => 'enable',
        command   => 'run',
        default   => ['matches'],
        matches   => 'number-literal',
        nothing   => 'nonesuch',
        malformed => q{}
    },
    {
        kind      => 'since',
        setting   => 'since',
        command   => 'list',
        default   => [],
        matches   => 'HEAD',
        nothing   => 'HEAD',
        malformed => 'no..such..revision'
    },
    {
        kind      => 'perl',
        setting   => 'perl',
        command   => 'run',
        default   => ['matches'],
        matches   => $^X,
        nothing   => '/nonesuch/bin/perl',
        malformed => q{}
    },
    {
        kind      => 'config',
        setting   => 'config',
        command   => 'list',
        default   => [qw(matches nothing malformed)],
        matches   => 'ci.toml',
        nothing   => 'absent.toml',
        malformed => 'broken.toml'
    },
    {
        kind      => 'root',
        setting   => 'root',
        command   => 'list',
        default   => ['matches'],
        matches   => q{.},
        nothing   => 'absent',
        malformed => 'lib/Tiny.pm'
    },
    {
        kind      => 'merge',
        command   => 'merge',
        origins   => ['line'],
        matches   => 'part.json',
        nothing   => 'absent.json',
        malformed => 'broken.json'
    },
    {
        kind      => 'suppression',
        command   => 'list',
        origins   => ['source'],
        matches   => 'arithmetic',
        nothing   => 'nonesuch',
        malformed => q{(}
    },
);
my @STATES = qw(matches nothing malformed);

sub states () {
    return [@STATES];
}

sub selectors () {
    my %setting = map { $_->name => $_ } $SETTINGS->@*;
    my @selectors;
    for my $selector (@SELECTORS) {
        my %with = ( $selector->%*, row => defined $selector->{setting} ? $setting{ $selector->{setting} } : undef );
        push @selectors, \%with;
    }
    return \@selectors;
}

# Where a user may write a selector: in the file when it has a key, and on the command line when it has a flag.
sub origins ($selector) {
    return { map { $_ => [@STATES] } $selector->{origins}->@* } if $selector->{origins};
    my $row = $selector->{row};
    return {
        ( $selector->{default}->@* ? ( default => $selector->{default} ) : () ),
        ( $row->key                ? ( file    => [@STATES] )            : () ),
        ( defined $row->flag       ? ( line    => [@STATES] )            : () ),
    };
}

my %TINY = (
    'lib/Tiny.pm'  => "package Tiny;\nuse strict;\nuse warnings;\nsub double { return \$_[0] + \$_[0] }\n1;\n",
    'lib/Other.pm' => "package Other;\nuse strict;\nuse warnings;\nsub one { return 1 }\n1;\n",
    't/tiny.t'     => "use Test::More tests => 1;\nuse Tiny;\nis Tiny::double(2), 4, 'the double';\n",
    'ci.toml'      => "jobs = 1\n",
    'broken.toml'  => "jobs = = 1\n",
    'broken.json'  => "{\n",
    'part.json'    => Test::Mutation::Report::Json::render(
        Samples::result( statuses => ['Killed'], shard => '1/1', inventory => { mutants => 1, digest => 'a' x 64 } ),
        high => 80,
        low  => 60
    ),
);

sub _git ( $root, @arguments ) {
    my @identity = map { ( '-c', $_ ) } 'core.hooksPath=/dev/null', 'user.name=Test', 'user.email=test@example.invalid',
      'commit.gpgsign=false';
    system( 'git', '-C', $root, @identity, @arguments ) == 0 or die "git @arguments failed\n";
    return;
}

# A project of two modules and one test, with the files that the case changes: a text replaces a file, and nothing removes it.
sub tree (%change) {
    my $root  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my %files = ( %TINY, %change );
    Fixture::write_file( "$root/$_", $files{$_} ) for grep { defined $files{$_} } sort keys %files;
    return $root;
}

# The files that a case changes in the project, for a selector that stands in the project and not on the command line.
sub _changes ( $selector, $origin, $state, $value ) {
    my ( $kind, $row ) = $selector->@{qw(kind row)};
    if ( $kind eq 'suppression' ) {
        my $comment = $state eq 'malformed' ? "## no mutate $value" : "## no mutate ($value)";
        return ( 'lib/Tiny.pm' => $TINY{'lib/Tiny.pm'} =~ s/( [}])\n/$1    $comment\n/r );
    }
    if ( $origin eq 'file' ) {
        my ( $section, $key ) = $row->key->@*;
        my $text = q{"} . $value =~ s/\\/\\\\/gr . q{"};
        return ( 'mutation.toml' => "[$section]\n$key = " . ( $row->kind eq 'list' ? "[$text]" : $text ) . "\n" );
    }
    return if $origin ne 'default' || $state eq 'matches' && $kind ne 'config';
    return ( 'lib/Tiny.pm' => undef, 'lib/Other.pm' => undef ) if $kind eq 'source';
    return ( 't/tiny.t' => undef )                             if $kind eq 'test';
    return                                                     if $state eq 'nothing';
    return ( 'mutation.toml' => $TINY{ $state eq 'matches' ? 'ci.toml' : 'broken.toml' } );
}

# The project, the command line, and the expectation of one case.
sub _selection ( $selector, $origin, $state, $identifier ) {
    my ( $kind, $row, $command ) = $selector->@{qw(kind row command)};
    my $value = $kind eq 'mutant' && $state eq 'matches' ? $identifier : $selector->{$state};
    my @line  = ( $command, $command eq 'list' ? () : ( '--format', 'terminal' ) );

    # One mutant keeps a run short, and the run still reads its tests and its interpreter.
    push @line, '--jobs', 1, '--mutant', $identifier if $command eq 'run';
    push @line, ( defined $row ? $row->flag : () ), $value if $origin eq 'line';

    # A selector that the user wrote and that selects nothing is a usage error, and so is a broken default file.
    # No change since a revision is an honest empty answer.
    my $written = $origin ne 'default' || $state eq 'malformed';
    my $honest  = $state eq 'matches'  || $kind eq 'since' && $state eq 'nothing';
    return {
        kind   => $kind,
        origin => $origin,
        state  => $state,
        change => { _changes( $selector, $origin, $state, $value ) },
        argv   => \@line,
        exit   => $written && !$honest ? 2               : 0,
        named  => $origin eq 'default' ? 'mutation.toml' : $value,
    };
}

sub selections ($identifier) {
    my @cases;
    for my $selector ( selectors()->@* ) {
        my $origins = origins($selector);
        for my $origin ( sort keys $origins->%* ) {
            push @cases, map { _selection( $selector, $origin, $_, $identifier ) } $origins->{$origin}->@*;
        }
    }
    return \@cases;
}

# The project of a case, in the state that the case calls for.
sub selection_tree ($case) {
    my $root = tree( $case->{change}->%* );
    return $root if $case->{kind} ne 'since';
    _git( $root, 'init',   '-q' );
    _git( $root, 'add',    q{.} );
    _git( $root, 'commit', '-q', '-m', 'the project' );
    Fixture::write_file( "$root/lib/Tiny.pm", $TINY{'lib/Tiny.pm'} =~ s/[+]/*/r ) if $case->{state} eq 'matches';
    return $root;
}

# S6, the reports: the sets of statuses that a result holds, each status once present and once absent.
sub result_sets () {
    my @names = map { $_->name } Test::Mutation::Status::rows()->@*;
    my @sets  = ( [ 'none', [] ], [ 'all', [@names] ] );
    for my $name (@names) {
        push @sets, [ "only-$name", [$name] ], [ "all-but-$name", [ grep { $_ ne $name } @names ] ];
    }
    return \@sets;
}

# The shapes of a source and its changes: the letters next to the code, and the lines that a change spans.
sub shapes () {
    my @shapes;
    for my $letters ( Samples::letters()->@* ) {
        push @shapes, map { { label => "$letters-$_", letters => $letters, lines => $_ } } 1, 2;
    }
    return \@shapes;
}

# S2, the pairs: two settings on one command line, under each state of the environment that the command reads.
sub environments () {
    my @environments;
    for my $github ( 0, 1 ) {
        for my $plain ( 0, 1 ) {
            for my $terminal ( 0, 1 ) {
                my @named = (
                    ( $github   ? 'GITHUB_ACTIONS' : () ),
                    ( $plain    ? 'NO_COLOR'       : () ),
                    ( $terminal ? 'terminal'       : () )
                );
                my %env = ( ( $github ? ( GITHUB_ACTIONS => 'true' ) : () ), ( $plain ? ( NO_COLOR => '1' ) : () ) );
                push @environments,
                  {
                    label => @named ? join( q{+}, @named ) : 'plain',
                    named => \@named,
                    fact  => { env => \%env, out_tty => $terminal, err_tty => $terminal },
                  };
            }
        }
    }
    return \@environments;
}

# What a part of the environment may change today: the attributes of the plan, and the stream of the output.
my %DECLARED =
  ( GITHUB_ACTIONS => { attributes => ['formats'], streams => ['stdout'] }, terminal => { streams => ['stderr'] } );

sub declared ( $named, $kind ) {
    return { map { $_ => 1 } map { @{ $DECLARED{$_}{$kind} || [] } } $named->@* };
}

# The settings of a plan as texts.
sub config_text ($config) {
    return { map { $_->attribute => value_text( $_, $config ) } grep { defined $_->attribute } $SETTINGS->@* };
}

# The words that set one setting on the command line to its first sample.
sub flag_words ($setting) {
    return on_surface( $setting, 'flag', samples($setting)->{valid}[0] );
}

# The findings of one invariant.
# A violation is what broke, and the values of two dimensions where it broke, such as a flag and a command.
# A dimension that the violation holds across folds into the text, so one cause gives one line.
# The names of a line stand in the order of their letters, so the repair of one violation leaves the other lines as they are.
sub folded ( $violations, $first = 'flags', $second = 'commands' ) {
    my %cover;
    for my $violation ( $violations->@* ) {
        my ( $what, $one, $other ) = $violation->@*;
        $cover{$what}{$one}{$other} = 1;
    }
    my $listed = sub (@names) { join q{ }, sort @names };
    my @lines;
    for my $what ( sort keys %cover ) {
        my %ones;
        for my $one ( keys $cover{$what}->%* ) {
            push $ones{ $listed->( keys $cover{$what}{$one}->%* ) }->@*, $one;
        }
        push @lines, map { join q{; }, $what, "$first " . $listed->( $ones{$_}->@* ), "$second $_" } sort keys %ones;
    }
    return \@lines;
}

1;
