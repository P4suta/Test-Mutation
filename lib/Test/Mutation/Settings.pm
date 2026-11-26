package Test::Mutation::Settings;
use v5.36;
use File::Spec             ();
use List::Util             ();
use TOML::Tiny             ();
use Type::Tiny             ();
use Types::Standard        qw(ArrayRef Bool CodeRef Dict Enum HashRef InstanceOf Int Maybe Optional Str StrictNum);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Host;
use Test::Mutation::Launch;
use Test::Mutation::Project;
use Test::Mutation::Setting;

our $VERSION = '0.001';

# The largest whole number that a number of Perl holds exactly, and a number that no finite number reaches.
my $LARGEST  = 9_007_199_254_740_992;
my $INFINITY = 9**9**9;

sub _type ( $name, $parent, @constraint ) {
    return Type::Tiny->new( name => $name, parent => $parent, map { ( constraint => $_ ) } @constraint );
}

my $COUNT      = _type( 'Count',      Int,       sub { $_ >= 1                            && $_ <= $LARGEST } );
my $POSITIVE   = _type( 'Positive',   StrictNum, sub { $_ > 0                             && $_ < $INFINITY } );
my $PERCENT    = _type( 'Percent',    StrictNum, sub { $_ >= 0                            && $_ <= 100 } );
my $SHARD      = _type( 'Shard',      Str,       sub { m{\A([1-9][0-9]*)/([1-9][0-9]*)\z} && $1 <= $2 } );
my $COVERAGE   = _type( 'Coverage',   Enum [qw(line file)] );
my $PROFILE    = _type( 'Profile',    Enum [qw(default extended)] );
my $FORMAT     = _type( 'Format',     Enum [qw(terminal json html github)] );
my $BOOLEAN    = _type( 'Boolean',    Bool );
my $DIRECTORY  = _type( 'Directory',  Str );
my $FILE       = _type( 'File',       Str );
my $PROGRAM    = _type( 'Program',    Str );
my $PATH       = _type( 'Path',       Str );
my $GLOB       = _type( 'Glob',       Str );
my $SWITCH     = _type( 'Switch',     Str );
my $REVISION   = _type( 'Revision',   Str );
my $IDENTIFIER = _type( 'Identifier', Str );
my $MUTATOR    = _type( 'Mutator',    Str );

# A type of numbers gives the number of the text, and the configuration file writes each type with the kinds of TOML here.
my %NUMBER = map { $_ => 1 } qw(Count Positive Percent);
my %TOML =
  ( Count => ['integer'], Positive => [qw(integer float)], Percent => [qw(integer float)], Boolean => ['boolean'] );

# A variable that the environment leaves out reads as an empty text.
sub _inside_github_actions ($env) {
    my ($hosted) = grep { defined } $env->{GITHUB_ACTIONS}, q{};
    return $hosted eq 'true' ? 1 : 0;
}

# Each row: the name, the short option, the kind, the type, the placeholder, the values it takes, the default and its text,
# the group, the help, and the facts that differ from the most rows.
my @ROWS = (
    [
        'root', '-C', 'value', $DIRECTORY, 'DIR', 'a directory', sub { q{.} },
        q{.},   'project',
        'Run as if mutation had started in DIR',
        { surfaces => [qw(line call)] }
    ],
    [
        'config', undef, 'value', $FILE, 'FILE', 'a file', undef, 'mutation.toml when it exists',
        'project',
        'Configuration file to read in place of mutation.toml',
        { surfaces => [qw(line call)] }
    ],
    [
        'jobs',
        '-j',
        'value',
        $COUNT,
        'N',
        'a whole number above zero',
        sub ($facts) { Test::Mutation::Project::default_jobs( $facts->{processors} ) },
        'one less than the processors, and at least one',
        'tests',
        'Test processes to run side by side'
    ],
    [
        'color', undef, 'flag', $BOOLEAN, undef,
        'true or false',
        sub ($facts) { return $facts->{terminal} && !length( $facts->{env}{NO_COLOR} ) ? 1 : 0 },
        'on for a terminal without NO_COLOR',
        'report', 'Color the progress and the terminal report'
    ],
    [
        'min-score', undef,  'value',  $PERCENT, 'N', 'a number from 0 to 100',
        undef,       'none', 'report', 'Fail when the score is below N percent'
    ],
    [
        'format',
        undef,
        'list',
        $FORMAT,
        'NAME',
        'a list of terminal, json, html, and github',
        sub ($facts) { [ qw(terminal json html), _inside_github_actions( $facts->{env} ) ? 'github' : () ] },
        'terminal json html, and github inside GitHub Actions',
        'report',
        'Report to write: terminal, json, html, github; repeatable'
    ],
    [
        'report-dir',      undef,    'value', $DIRECTORY, 'DIR', 'a directory', sub { 'mutation-report' },
        'mutation-report', 'report', 'Directory for the report files'
    ],
    [
        'threshold-high', undef, 'value', $PERCENT, 'N',
        'a number from 0 to 100',
        sub { 80 },
        '80', 'report', 'Score from which a report marks the result as good'
    ],
    [
        'threshold-low', undef, 'value', $PERCENT, 'N',
        'a number from 0 to 100',
        sub { 60 },
        '60', 'report', 'Score below which a report marks the result as poor'
    ],
    [
        'perl',  undef,                   'value',     $PROGRAM,
        'PATH',  'the path of a program', sub { $^X }, 'the running interpreter',
        'tests', 'Interpreter that runs the tests'
    ],
    [
        'lib',
        undef,
        'list',
        $DIRECTORY,
        'DIR',
        'a list of library directories',
        sub ($facts) { return $facts->{launch} ? $facts->{launch}{lib} : ['lib'] },
        'lib, or blib for a distribution that builds',
        'tests',
        'Directory to search for Perl modules'
    ],
    [
        'switch', undef, 'list', $SWITCH, 'SWITCH',
        'a list of switches of perl',
        sub ($facts) { return $facts->{launch} ? $facts->{launch}{switch} : [] },
        'none', 'tests', 'Switch of the interpreter of the tests; repeatable'
    ],
    [
        'source', undef, 'list', $GLOB, 'GLOB',
        'a list of globs',
        sub { [qw(lib/**/*.pm bin/**/* script/**/*)] },
        'lib/**/*.pm and the Perl scripts of bin and script',
        'selection', 'Files to mutate; repeatable'
    ],
    [
        'source-exclude', undef, 'list', $GLOB, 'GLOB',
        'a list of globs',
        sub { [] },
        'none', 'selection', 'Files to leave unmutated; repeatable'
    ],
    [
        'test', undef, 'list', $GLOB, 'GLOB',
        'a list of globs',
        sub { ['t/**/*.t'] },
        't/**/*.t', 'selection', 'Test files; repeatable'
    ],
    [
        'test-exclude', undef, 'list', $GLOB, 'GLOB',
        'a list of globs',
        sub { [] },
        'none', 'selection', 'Test files to leave out; repeatable'
    ],
    [
        'profile', undef, 'value', $PROFILE, 'NAME',
        'default or extended',
        sub { 'default' },
        'default', 'mutators', 'Mutator profile: default or extended'
    ],
    [
        'enable',   undef,                         'list',     $MUTATOR,
        'NAME',     'a list of names of mutators', sub { [] }, 'none',
        'mutators', 'Add a mutator; repeatable'
    ],
    [
        'disable',  undef,                         'list',     $MUTATOR,
        'NAME',     'a list of names of mutators', sub { [] }, 'none',
        'mutators', 'Remove a mutator; repeatable'
    ],
    [
        'equivalence', undef, 'flag', $BOOLEAN, undef,
        'true or false',
        sub { 1 },
        'on', 'mutators', 'Leave out the mutants that compile to the code of the original'
    ],
    [
        'suppress-require-names', undef, 'flag', $BOOLEAN, undef,
        'true or false',
        sub { 0 },
        'off', 'mutators', 'Require each suppression comment to name its mutators'
    ],
    [
        'suppress-require-reason', undef, 'flag', $BOOLEAN, undef,
        'true or false',
        sub { 0 },
        'off', 'mutators', 'Require each suppression comment to give a reason'
    ],
    [
        'coverage', undef,   'value', $COVERAGE, 'MODE', 'line or file', sub { 'line' },
        'line',     'tests', 'Select tests by line or by file'
    ],
    [
        'timeout-factor', undef, 'value', $POSITIVE, 'N',
        'a number above zero',
        sub { 4 },
        '4', 'tests', 'Time limit as a multiple of the unmodified duration'
    ],
    [
        'timeout-floor', undef, 'value', $POSITIVE, 'SECONDS',
        'a number above zero',
        sub { 10 },
        '10', 'tests', 'Smallest time limit in seconds'
    ],
    [
        'baseline-timeout', undef, 'value', $POSITIVE, 'SECONDS',
        'a number above zero',
        sub { 600 },
        '600', 'tests', 'Time limit in seconds for a test of the unmodified run'
    ],
    [
        'in-place', undef, 'flag', $BOOLEAN, undef,
        'true or false',
        sub { 0 },
        'off', 'tests', 'Run the tests in the project itself, not in copies of it'
    ],
    [
        'link', undef, 'list', $PATH, 'PATH',
        'a list of paths',
        sub { ['local'] },
        'local', 'tests', 'Path that a copy holds as a link to the project; repeatable'
    ],
    [
        'keep-work', undef, 'flag', $BOOLEAN, undef,
        'true or false',
        sub { 0 },
        'off', 'cache', 'Keep the work directory after the run'
    ],
    [
        'mutant', undef, 'list', $IDENTIFIER, 'ID',
        'a list of mutant identifiers',
        sub { [] },
        'none', 'selection',
        'Rerun the named mutant and confirm a kill or survival with a second attempt (repeatable)',
        { selects => 1 }
    ],
    [
        'since', undef,  'value', $REVISION, 'REVISION', 'a Git revision',
        undef,   'none', 'selection',
        'Cover the lines changed since a Git revision',
        { selects => 1 }
    ],
    [
        'shard', undef,  'value', $SHARD, 'K/N', 'a part K/N with K from 1 to N',
        undef,   'none', 'selection',
        'Cover part K of N equal parts of the mutants',
        { selects => 1 }
    ],
    [
        'cache', undef, 'flag', $BOOLEAN, undef,
        'true or false',
        sub { 1 },
        'on', 'cache', 'Reuse the results of an earlier run where the inputs are unchanged'
    ],
    [
        'cache-dir', undef,   'value', $DIRECTORY, 'DIR', 'a directory', sub { '.mutation' },
        '.mutation', 'cache', 'Directory for cached measurement results'
    ],
);

sub _row ( $name, $short, $kind, $type, $placeholder, $expects, $default, $default_text, $group, $help, $other = {} ) {
    return Test::Mutation::Setting->new(
        name         => $name,
        short        => $short,
        kind         => $kind,
        type         => $type,
        placeholder  => $placeholder,
        expects      => $expects,
        default      => $default,
        default_text => $default_text,
        group        => $group,
        help         => $help,
        surfaces     => [qw(line file call)],
        $other->%*,
    );
}

my @SETTINGS     = map { _row( $_->@* ) } @ROWS;
my %BY_NAME      = map { $_->name      => $_ } @SETTINGS;
my %BY_ATTRIBUTE = map { $_->attribute => $_ } @SETTINGS;
my @FILE_KEYS    = map { $_->key } grep       { $_->offers('file') } @SETTINGS;
my @CALL_NAMES   = map { $_->attribute } grep { $_->offers('call') } @SETTINGS;

# Each row: the rule, the settings that it binds, and what it means for a run.
# The resolution checks the rules of an order and of an exclusion, and the outcome of a run follows the other two.
my @INTERACTIONS = (
    {
        rule        => 'order',
        settings    => [qw(threshold-low threshold-high)],
        description => 'The low threshold of the reports stays at or below the high one.'
    },
    {
        rule        => 'exclusive',
        settings    => [qw(in-place link)],
        description => 'A run in the project makes no copy, so it refuses a link that the user names.'
    },
    {
        rule        => 'defers',
        settings    => [qw(shard min-score)],
        description => 'A part of a split run leaves the gate of the score to merge.'
    },
    {
        rule        => 'updates-report',
        settings    => ['mutant'],
        description => 'A run of named mutants or paths updates the latest report of the same mutants.'
    },
);

my $SETTING     = InstanceOf ['Test::Mutation::Setting'];
my $VALUE       = Maybe [ Str | ArrayRef [Str] ];
my $ARGUMENT    = Maybe [ Str | ArrayRef [Str] | CodeRef ];
my $ENTRY       = Dict [ value      => $VALUE, spelled => Str, surface => Enum [qw(line file call)] ];
my $LAYER       = Dict [ origin     => Enum [qw(file line call)], name => Maybe [Str], entries => HashRef [$ENTRY] ];
my $FACTS       = Dict [ processors => PositiveInt, env => HashRef [ Maybe [Str] ], terminal => Optional [Bool] ];
my $CONFIG      = InstanceOf ['Test::Mutation::Config'];
my $INTERACTION = Dict [
    rule        => Enum [qw(order exclusive defers updates-report)],
    settings    => ArrayRef [Str],
    description => Str,
];

signature_for rows => ( positional => [], returns => ArrayRef [$SETTING] );

sub rows () {
    return [@SETTINGS];
}

signature_for interactions => ( positional => [], returns => ArrayRef [$INTERACTION] );

sub interactions () {
    return [@INTERACTIONS];
}

signature_for layer_type => ( positional => [], returns => InstanceOf ['Type::Tiny'] );

sub layer_type () {
    return $LAYER;
}

# The edits that turn one word into another: an insertion, a removal, or a change of one letter each count one.
sub _distance ( $one, $other ) {
    my @previous = 0 .. length $other;
    for my $row ( 1 .. length $one ) {
        my @current = ($row);
        for my $column ( 1 .. length $other ) {
            my $change = substr( $one, $row - 1, 1 ) eq substr( $other, $column - 1, 1 ) ? 0 : 1;
            push @current,
              List::Util::min( $previous[$column] + 1, $current[ $column - 1 ] + 1,
                $previous[ $column - 1 ] + $change );
        }
        @previous = @current;
    }
    return $previous[-1];
}

signature_for nearest => ( positional => [ Str, ArrayRef [ Str, 1 ] ], returns => Str );

sub nearest ( $word, $candidates ) {
    my @distances = map { _distance( $word, $_ ) } $candidates->@*;
    my $least     = List::Util::min(@distances);
    my ($first)   = grep { $distances[$_] == $least } 0 .. $#distances;
    return $candidates->[$first];
}

sub _refuse ( $setting, $spelled, $shown ) {
    return Test::Mutation::Error::raise(
        'setting-invalid',
        setting => $spelled,
        expects => $setting->expects,
        value   => $shown
    );
}

# One value of the type of a setting, or the refusal that names the setting as the user spelled it and the value as written.
sub _checked ( $setting, $value, $spelled, $shown ) {
    my $type = $setting->type;
    _refuse( $setting, $spelled, $shown ) if !$type->check($value);
    return $NUMBER{ $type->name } ? 0 + $value : $value;
}

signature_for decode => ( named => [ setting => $SETTING, given => Str, spelled => Str ], returns => Str );

sub decode ($arg) {
    return _checked( $arg->setting, $arg->given, $arg->spelled, $arg->given );
}

# The decoder marks each typed value of the file as a reference to its kind and its text, a form that no other value takes.
my %INFLATE = (
    inflate_integer  => sub ($text) { return \"integer $text" },
    inflate_float    => sub ($text) { return \"float $text" },
    inflate_boolean  => sub ($text) { return \"boolean $text" },
    inflate_datetime => sub ($text) { return \"datetime $text" },
);
my %KIND = ( q{} => 'string', ARRAY => 'array', HASH => 'table' );

# The kind and the text of a value of the file.
sub _toml_kind ($value) {
    return ref $value eq 'SCALAR' ? $value->$* =~ /\A(\w+) (.*)\z/s : ( $KIND{ ref $value }, $value );
}

# A value of the file as the file writes it.
sub _toml_text ($value) {
    my ( $kind, $text ) = _toml_kind($value);
    return '[' . join( q{, }, map { _toml_text($_) } $value->@* ) . ']' if $kind eq 'array';
    return $kind eq 'string' ? qq{"$text"} : $kind eq 'table' ? 'a table' : $text;
}

# A whole number of the file has the digits of base ten, so a number in another base is refused.
sub _toml_one ( $setting, $value, $spelled, $shown ) {
    my ( $kind, $text ) = _toml_kind($value);
    my $fits = grep { $_ eq $kind } @{ $TOML{ $setting->type->name } || ['string'] };
    _refuse( $setting, $spelled, $shown ) if !$fits || $kind eq 'integer' && $text !~ /\A-?[0-9]+\z/;
    return _checked( $setting, $kind eq 'boolean' ? ( $text eq 'true' ? 1 : 0 ) : $text, $spelled, $shown );
}

sub _from_toml ( $setting, $value, $spelled ) {
    my $shown = _toml_text($value);
    return _toml_one( $setting, $value, $spelled, $shown ) if $setting->kind ne 'list';
    _refuse( $setting, $spelled, $shown )                  if ref $value ne 'ARRAY';
    return [ map { _toml_one( $setting, $_, $spelled, $shown ) } $value->@* ];
}

# An empty name names no file, and the directory of the project counts as none.
sub _file_layer ( $root, $name ) {
    my $path = length $name ? File::Spec->rel2abs( $name, $root ) : $name;
    open my $handle, '<:encoding(UTF-8)', $path
      or Test::Mutation::Error::raise( 'input-unreadable', path => $name, reason => "$!" );
    my $text = do { local $/ = undef; join q{}, readline $handle };
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $name, reason => "$!" );
    my ( $data, $error ) = TOML::Tiny::from_toml( $text, %INFLATE );
    Test::Mutation::Error::raise( 'input-malformed', path => $name, reason => ( split /\n/, "$error" )[0] )
      if !defined $data;
    my %entries;
    for my $key ( sort keys $data->%* ) {
        my ( $value, $setting, $spelled ) = ( $data->{$key}, $BY_NAME{$key}, "$name: $key" );
        Test::Mutation::Error::raise( 'config-section',  file    => $name,    section => $key ) if ref $value eq 'HASH';
        Test::Mutation::Error::raise( 'setting-unknown', setting => $spelled, nearest => nearest( $key, \@FILE_KEYS ) )
          if !$setting;
        Test::Mutation::Error::raise( 'setting-outside-file', setting => $spelled ) if !$setting->offers('file');
        $entries{$key} = { value => _from_toml( $setting, $value, $spelled ), spelled => $spelled, surface => 'file' };
    }
    return { origin => 'file', name => $name, entries => \%entries };
}

# A value of a call as the caller wrote it.
sub _perl_text ($value) {
    return 'nothing' if !defined $value;
    return 'code'    if ref $value eq 'CODE';
    return ref $value ? '[' . join( q{, }, $value->@* ) . ']' : $value;
}

sub _call_layer ($arguments) {
    my %entries;
    for my $name ( sort keys $arguments->%* ) {
        my ( $value, $setting ) = ( $arguments->{$name}, $BY_ATTRIBUTE{$name} );
        Test::Mutation::Error::raise( 'setting-unknown', setting => $name, nearest => nearest( $name, \@CALL_NAMES ) )
          if !$setting;
        my $shown = _perl_text($value);
        _refuse( $setting, $name, $shown ) if $setting->kind eq 'list' && ref $value ne 'ARRAY';
        my $decoded =
          $setting->kind eq 'list'
          ? [ map { _checked( $setting, $_, $name, $shown ) } $value->@* ]
          : _checked( $setting, $value, $name, $shown );
        $entries{ $setting->name } = { value => $decoded, spelled => $name, surface => 'call' };
    }
    return { origin => 'call', name => undef, entries => \%entries };
}

# The text of a setting in a refusal: as the user spelled it with its value, or as a default in the words of the surface.
sub _said ( $setting, $entry, $value, $surface ) {
    my $number = $value->{ $setting->attribute };
    my $said   = $entry->{ $setting->name };
    return $said ? "$said->{spelled} $number" : $setting->spelled($surface) . " $number by default";
}

sub _ordered ( $entry, $value, $low, $high ) {
    return if $value->{ $low->attribute } <= $value->{ $high->attribute };
    my $surface = ( $entry->{ $low->name } || $entry->{ $high->name } )->{surface};
    return Test::Mutation::Error::raise(
        'settings-out-of-order',
        first  => _said( $low,  $entry, $value, $surface ),
        second => _said( $high, $entry, $value, $surface ),
    );
}

sub _exclusive ( $entry, $value, $switch, $partner ) {
    my ( $one, $other ) = map { $entry->{ $_->name } } $switch, $partner;
    return if !$one || !$value->{ $switch->attribute } || !$other;
    return Test::Mutation::Error::raise( 'settings-exclusive', first => $one->{spelled}, second => $other->{spelled} );
}

my %CHECK = ( order => \&_ordered, exclusive => \&_exclusive );

signature_for resolve => ( named => [ root => Str, layers => ArrayRef [$LAYER], facts => $FACTS ], returns => $CONFIG );

sub resolve ($arg) {

    # The configuration takes its types from this table, so it loads after the table.
    require Test::Mutation::Config;
    my ( %entry, $file );
    for my $layer ( $arg->layers->@* ) {
        %entry = ( %entry, $layer->{entries}->%* );
        $file  = $layer->{name} if $layer->{origin} eq 'file';
    }
    my $facts = { $arg->facts->%*, launch => Test::Mutation::Launch::defaults( $arg->root ) };
    my %value;
    for my $setting ( grep { $_->group ne 'project' } @SETTINGS ) {
        my $entry = $entry{ $setting->name };
        $value{ $setting->attribute } =
            $entry            ? $entry->{value}
          : $setting->default ? $setting->default->($facts)
          :                     undef;
    }
    for my $interaction ( grep { $CHECK{ $_->{rule} } } @INTERACTIONS ) {
        $CHECK{ $interaction->{rule} }->( \%entry, \%value, map { $BY_NAME{$_} } $interaction->{settings}->@* );
    }
    my %specified = map { $_ => $entry{$_}{spelled} } keys %entry;
    return Test::Mutation::Config->new( %value, root => $arg->root, config => $file, specified => \%specified );
}

signature_for configure => ( named => [ root => Str, given => $LAYER, facts => $FACTS ], returns => $CONFIG );

sub configure ($arg) {
    my $named = $arg->given->{entries}{config};
    my $name  = $named ? $named->{value} : 'mutation.toml';
    my $read  = $named || -e File::Spec->rel2abs( $name, $arg->root );
    my @file  = $read ? _file_layer( $arg->root, $name ) : ();
    return resolve( root => $arg->root, layers => [ @file, $arg->given ], facts => $arg->facts );
}

signature_for of_call => ( positional => [ HashRef [$ARGUMENT] ], returns => $CONFIG );

sub of_call ($arguments) {
    my $given = _call_layer($arguments);
    my $root  = $given->{entries}{root};
    return configure(
        root  => File::Spec->rel2abs( $root ? $root->{value} : q{.} ),
        given => $given,
        facts => { processors => Test::Mutation::Host::processors()->{count}, env => {%ENV} },
    );
}

1;

__END__

=head1 NAME

Test::Mutation::Settings - the table of the settings and the one way from the settings to a configuration

=head1 SYNOPSIS

    for my $setting ( Test::Mutation::Settings::rows()->@* ) {
        say join q{ }, $setting->flag, $setting->default_text;
    }

    my $config = Test::Mutation::Settings::of_call( { root => $directory, jobs => 2 } );

    my $same = Test::Mutation::Settings::configure(
        root  => $directory,
        given => { origin => 'line', name => undef, entries => {} },
        facts => { processors => 4, env => {} },
    );

=head1 DESCRIPTION

The table states every setting once: its name, its kind, its type, its default, its help, and the surfaces that offer it.
The command line, the configuration file, and a call of the library each decode what the user wrote into a layer.
A layer maps the name of each setting that it sets to the value and to the spelling that set it.
L</resolve> turns the layers into a L<Test::Mutation::Config>, and no other code builds one.

The configuration file holds one key for each setting and no sections.
It refuses a value whose kind of TOML differs from the type of its setting, such as the text C<"false"> for a flag.
It also refuses a whole number in another base than ten, a number without a finite value, and a number above the largest that Perl holds exactly.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Setting> for every setting, in the order of the help text.

=head2 interactions

Returns the ways in which one setting changes what another one does, each with its C<rule>, its C<settings>, and its C<description>.
No two settings interact in any other way.

=head2 layer_type

Returns the type of a layer: its C<origin>, the C<name> of its file, and its C<entries>.

=head2 nearest

    my $name = Test::Mutation::Settings::nearest( '--jobz', [ '--jobs', '--root' ] );

Returns the candidate that the fewest edits of one letter turn the word into, and the earliest one of a tie.

=head2 decode

    my $jobs = Test::Mutation::Settings::decode( setting => $setting, given => '4', spelled => '-j' );

Returns one value of the type of a setting from its text, as a number for a type of numbers.
It refuses a text outside the type with a usage error that names the setting as the user spelled it.

=head2 resolve

    my $config = Test::Mutation::Settings::resolve( root => $directory, layers => [ $file, $line ], facts => $facts );

Returns the configuration that the layers give, in rising priority.
The nearest layer that sets a setting gives its whole value, a list included, and the default of the table gives the rest.
C<facts> holds the count of the C<processors> and the C<env> that a default may depend on.
The function refuses settings that break an interaction of the table.

=head2 configure

Reads the configuration file of the directory and returns the configuration of the file and of the given layer.
The file is the one that the setting C<config> names, or F<mutation.toml> when it exists.

=head2 of_call

Returns the configuration of a call of the library, whose arguments name the settings by their attributes.
The directory is C<root>, or the working directory without one, and the facts are those of the process.

=cut
