package Test::Mutation::Settings;
use v5.36;
use Types::Standard qw(ArrayRef InstanceOf);
use Type::Params    qw(signature_for);
use Test::Mutation::Setting;

our $VERSION = '0.001';

my @TAKE_SETTINGS = qw(run list show exec merge);
my @EVERY_COMMAND = ( @TAKE_SETTINGS, qw(mutators help version) );
my %SHORT         = ( root => '-C', jobs => '-j' );
my %NEGATABLE     = map { $_ => 1 } qw(equivalence cache in_place);

# Each row: the flag, the section and the key of the file, the attribute, the kind, the type, and the default.
my @ROWS = (
    [ '--root',   undef, 'root', 'value', 'directory', q{.} ],
    [ '--config', undef, undef,  'value', 'file',      'mutation.toml' ],
    [ '--jobs',   [ q{},      'jobs' ],     'jobs',           'value', 'positive-integer', '1' ],
    [ '--source', [ 'source', 'include' ],  'source_include', 'list',  'glob',             'lib/**/*.pm' ],
    [ undef,      [ 'source', 'exclude' ],  'source_exclude', 'list',  'glob',             q{} ],
    [ '--test',   [ 'test',   'include' ],  'test_include',   'list',  'glob',             't/**/*.t' ],
    [ undef,      [ 'test',   'exclude' ],  'test_exclude',   'list',  'glob',             q{} ],
    [ '--perl',   [ 'test',   'perl' ],     'perl',           'value', 'program',          'the running interpreter' ],
    [ undef,      [ 'test',   'switches' ], 'switches',       'list',  'switch',           '-Ilib' ],
    [ '--timeout-factor', [ 'test', 'timeout-factor' ], 'timeout_factor', 'value', 'positive-number', '4' ],
    [ '--timeout-floor',  [ 'test', 'timeout-floor' ],  'timeout_floor',  'value', 'positive-number', '10' ],
    [ undef,              undef, 'baseline_timeout', 'value', 'positive-number', '600' ],
    [ '--coverage',    [ 'test',       'coverage' ],  'coverage',         'value', 'coverage',  'line' ],
    [ '--profile',     [ 'mutators',   'profile' ],   'profile',          'value', 'profile',   'default' ],
    [ '--enable',      [ 'mutators',   'enable' ],    'enable',           'list',  'mutator',   q{} ],
    [ '--disable',     [ 'mutators',   'disable' ],   'disable',          'list',  'mutator',   q{} ],
    [ '--report-dir',  [ 'report',     'directory' ], 'report_directory', 'value', 'directory', 'mutation-report' ],
    [ '--format',      [ 'report',     'formats' ],   'formats',          'list',  'format',    'terminal json html' ],
    [ undef,           [ 'thresholds', 'high' ],      'threshold_high',   'value', 'percent',   '80' ],
    [ undef,           [ 'thresholds', 'low' ],       'threshold_low',    'value', 'percent',   '60' ],
    [ '--min-score',   [ 'thresholds', 'break' ],     'threshold_break',  'value', 'percent',   q{} ],
    [ undef,           undef,                         'work_directory', 'value', 'directory',  '.mutation' ],
    [ '--keep-work',   undef,                         'keep_work',      'flag',  'boolean',    'off' ],
    [ '--since',       undef,                         'since',          'value', 'revision',   q{} ],
    [ '--mutant',      undef,                         'only',           'list',  'identifier', q{} ],
    [ '--shard',       undef,                         'shard',          'value', 'shard',      q{} ],
    [ '--equivalence', [ 'mutators', 'equivalence' ], 'equivalence',    'flag',  'boolean',    'on' ],
    [ '--cache',       [ q{}, 'cache' ],              'cache',          'flag',  'boolean',    'off' ],
    [ '--in-place',    [ 'test', 'in-place' ],        'in_place',       'flag',  'boolean',    'off' ],
    [ undef,           [ 'test', 'link' ],            'link',           'list',  'path',       'local' ],
);

# A row has the name of its attribute, and the row without one has the name of its flag.
sub _row ( $flag, $key, $attribute, $kind, $type, $default ) {
    my $name = defined $attribute ? $attribute : $flag =~ s/\A--//r =~ tr/-/_/r;
    return Test::Mutation::Setting->new(
        name         => $name,
        flag         => $flag,
        short        => $SHORT{$name},
        negatable    => $NEGATABLE{$name} ? 1 : 0,
        key          => $key,
        attribute    => $attribute,
        kind         => $kind,
        type         => $type,
        default_text => $default,
        commands     => !defined $flag ? [] : $name eq 'root' ? [@EVERY_COMMAND] : [@TAKE_SETTINGS],
    );
}

signature_for rows => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Setting'] ] );

sub rows () {
    return [ map { _row( $_->@* ) } @ROWS ];
}

1;

__END__

=head1 NAME

Test::Mutation::Settings - the table of the settings

=head1 SYNOPSIS

    for my $setting ( Test::Mutation::Settings::rows()->@* ) {
        say $setting->name;
    }

=head1 DESCRIPTION

The table states every setting once, with its name on the command line, in the configuration file, and in the library.
It describes the command as it stands, with the surfaces that a setting lacks.
A test compares the table with the options, the keys, and the attributes that the code accepts.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Setting> for every setting, in the order of the table.

=cut
