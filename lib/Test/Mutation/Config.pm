package Test::Mutation::Config;
use v5.36;
use Moo;
use Types::Standard        qw(ArrayRef Bool Enum HashRef InstanceOf Maybe Num Str);
use Types::Common::Numeric qw(PositiveInt PositiveNum);
use Type::Params           qw(signature_for);
use TOML::Tiny             ();

our $VERSION = '0.001';

my $PERCENT = Num->where( sub { $_ >= 0 && $_ <= 100 } );
my $FORMAT  = Enum [qw(terminal json html github)];
my $SHARD   = Str->where( sub { m{\A([1-9][0-9]*)/([1-9][0-9]*)\z} && $1 <= $2 } );

has root             => ( is => 'ro', isa => Str,         required => 1 );
has jobs             => ( is => 'ro', isa => PositiveInt, default  => 1 );
has source_include   => ( is => 'ro', isa => ArrayRef [Str], default => sub { ['lib/**/*.pm'] } );
has source_exclude   => ( is => 'ro', isa => ArrayRef [Str], default => sub { [] } );
has test_include     => ( is => 'ro', isa => ArrayRef [Str], default => sub { ['t/**/*.t'] } );
has test_exclude     => ( is => 'ro', isa => ArrayRef [Str], default => sub { [] } );
has perl             => ( is => 'ro', isa => Str, default => sub { $^X } );
has switches         => ( is => 'ro', isa => ArrayRef [Str], default => sub { ['-Ilib'] } );
has timeout_factor   => ( is => 'ro', isa => PositiveNum, default => 4 );
has timeout_floor    => ( is => 'ro', isa => PositiveNum, default => 10 );
has baseline_timeout => ( is => 'ro', isa => PositiveNum, default => 600 );
has coverage         => ( is => 'ro', isa => Enum [qw(line file)],        default => 'line' );
has profile          => ( is => 'ro', isa => Enum [qw(default extended)], default => 'default' );
has enable           => ( is => 'ro', isa => ArrayRef [Str], default => sub { [] } );
has disable          => ( is => 'ro', isa => ArrayRef [Str], default => sub { [] } );
has report_directory => ( is => 'ro', isa => Str, default => 'permutl-report' );
has formats          => ( is => 'ro', isa => ArrayRef [$FORMAT], default => sub { [qw(terminal json html)] } );
has threshold_high   => ( is => 'ro', isa => $PERCENT, default => 80 );
has threshold_low    => ( is => 'ro', isa => $PERCENT, default => 60 );
has threshold_break  => ( is => 'ro', isa => Maybe [$PERCENT], default => undef );
has work_directory   => ( is => 'ro', isa => Str,  default => '.permutl' );
has keep_work        => ( is => 'ro', isa => Bool, default => 0 );
has since            => ( is => 'ro', isa => Maybe [Str],    default => undef );
has only             => ( is => 'ro', isa => ArrayRef [Str], default => sub { [] } );
has shard            => ( is => 'ro', isa => Maybe [$SHARD], default => undef );
has equivalence      => ( is => 'ro', isa => Bool, default => 1 );
has cache            => ( is => 'ro', isa => Bool, default => 0 );
has in_place         => ( is => 'ro', isa => Bool, default => 0 );
has link             => ( is => 'ro', isa => ArrayRef [Str], default => sub { ['local'] } );

my %FILE_KEYS = (
    q{}    => { jobs    => 'jobs',           cache   => 'cache' },
    source => { include => 'source_include', exclude => 'source_exclude' },
    test   => {
        include          => 'test_include',
        exclude          => 'test_exclude',
        perl             => 'perl',
        switches         => 'switches',
        'timeout-factor' => 'timeout_factor',
        'timeout-floor'  => 'timeout_floor',
        coverage         => 'coverage',
        'in-place'       => 'in_place',
        link             => 'link',
    },
    mutators   => { profile   => 'profile', enable => 'enable', disable => 'disable', equivalence => 'equivalence' },
    report     => { directory => 'report_directory', formats => 'formats' },
    thresholds => { high      => 'threshold_high',   low     => 'threshold_low', break => 'threshold_break' },
);

signature_for read_file => ( positional => [Str], returns => HashRef );

sub read_file ($path) {
    open my $handle, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "cannot close $path: $!\n";
    my ( $data, $error ) = TOML::Tiny::from_toml($text);
    die "$path: " . ( split /\n/, "$error" )[0] . "\n" if !defined $data;
    return $data;
}

signature_for from_layers => (
    method  => 1,
    named   => [ root => Str, file => HashRef, cli => HashRef, defaults => HashRef ],
    returns => InstanceOf ['Test::Mutation::Config'],
);

sub from_layers ( $class, $arg ) {
    my %settings = ( $arg->defaults->%*, _file_settings( $arg->file ), $arg->cli->%* );
    return $class->new( %settings, root => $arg->root );
}

sub _file_settings ($file) {
    my %settings;
    for my $key ( sort keys $file->%* ) {
        my $value = $file->{$key};
        if ( ref $value eq 'HASH' ) {
            my $section = $FILE_KEYS{$key} or die "unknown configuration section [$key]\n";
            for my $name ( sort keys $value->%* ) {
                my $attribute = $section->{$name} or die "unknown configuration key $name in [$key]\n";
                $settings{$attribute} = $value->{$name};
            }
        }
        else {
            my $attribute = $FILE_KEYS{q{}}{$key} or die "unknown configuration key $key\n";
            $settings{$attribute} = $value;
        }
    }
    return %settings;
}

1;

__END__

=head1 NAME

Test::Mutation::Config - the validated settings of a run

=head1 SYNOPSIS

    my $config = Test::Mutation::Config->from_layers(
        root     => $directory,
        defaults => { jobs => 4 },
        file     => $parsed_toml,
        cli      => { profile => 'extended' },
    );

=head1 DESCRIPTION

A configuration is an immutable value.
Every attribute has a type, and construction fails on a value outside it.

=head1 METHODS

=head2 from_layers

Builds a configuration from defaults, the parsed configuration file, and command line settings, in rising priority.
The file uses sections and hyphenated keys, and an unknown section or key is a fatal error.

=head1 FUNCTIONS

=head2 read_file

    my $parsed = Test::Mutation::Config::read_file('permutl.toml');

Returns the parsed content of a configuration file, and dies with the path and the first line of the error when the file is malformed.

=head1 ATTRIBUTES

=head2 root

The project directory.

=head2 jobs

The number of test processes that run side by side.

=head2 source_include, source_exclude

Glob patterns for the files to mutate.

=head2 test_include, test_exclude

Glob patterns for the test files.

=head2 perl

The interpreter that runs the tests.

=head2 switches

Switches for the interpreter, C<-Ilib> by default.
The run names a relative directory after C<-I> in full, as C<prove> does, so a test may change its directory.

=head2 timeout_factor, timeout_floor

A test may run for the larger of the floor in seconds and the factor times its unmodified duration.

=head2 baseline_timeout

The time limit in seconds for a test in the unmodified run.

=head2 coverage

C<line> selects tests by the lines they ran, C<file> by the files they loaded.

=head2 profile, enable, disable

The mutator profile and the names added to or removed from it.

=head2 report_directory, formats

Where reports go and which ones to write.

=head2 threshold_high, threshold_low, threshold_break

Score percentages for report colors, and the score below which the run fails.

=head2 work_directory, keep_work

The directory for temporary files, and whether to keep it after the run.

=head2 in_place, link

The tests run in copies of the project, which a run makes in the temporary directory.
C<in_place> runs them in the project itself.
C<link> names the paths that a copy holds as links to the original, C<local> by default.

=head2 since

A Git revision; when set, the run covers the lines changed since it.

=head2 only

Mutant identifiers; when set, the run covers these mutants.

=head2 shard

A part of the mutants as C<K/N>; the run covers every Nth mutant, starting at the Kth.
N runs with K from 1 to N cover every mutant once.

=head2 equivalence

Whether the run compares the compiled code of an undetected mutant with the original, true by default.
A mutant that compiles to the same code is ignored, and so is a mutant with the code of an earlier undetected mutant.

=head2 cache

Whether the run reuses results from C<cache.json> in the work directory and writes its own, false by default.
The key of a result covers the mutated file, the tests that reach the mutant, and the analyzed source files those tests load.
The key also covers every other file under the top-level directories of the sources and the tests, so a change there measures every mutant again.
A change outside those directories, such as a new version of a dependency, needs a run without the cache.

=cut
