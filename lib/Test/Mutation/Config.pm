package Test::Mutation::Config;
use v5.36;
use Moo;
use Test::Mutation::Settings;

our $VERSION = '0.001';

with 'Test::Mutation::Value';

# Each attribute takes its type from the row of its setting, and the resolution of the settings gives every value.
my %TYPE = map { $_->attribute => $_->value_type } Test::Mutation::Settings::rows()->@*;

has root             => ( is => 'ro', isa => $TYPE{root},             required => 1 );
has config           => ( is => 'ro', isa => $TYPE{config},           required => 1 );
has jobs             => ( is => 'ro', isa => $TYPE{jobs},             required => 1 );
has min_score        => ( is => 'ro', isa => $TYPE{min_score},        required => 1 );
has format           => ( is => 'ro', isa => $TYPE{format},           required => 1 );
has report_dir       => ( is => 'ro', isa => $TYPE{report_dir},       required => 1 );
has threshold_high   => ( is => 'ro', isa => $TYPE{threshold_high},   required => 1 );
has threshold_low    => ( is => 'ro', isa => $TYPE{threshold_low},    required => 1 );
has perl             => ( is => 'ro', isa => $TYPE{perl},             required => 1 );
has switch           => ( is => 'ro', isa => $TYPE{switch},           required => 1 );
has source           => ( is => 'ro', isa => $TYPE{source},           required => 1 );
has source_exclude   => ( is => 'ro', isa => $TYPE{source_exclude},   required => 1 );
has test             => ( is => 'ro', isa => $TYPE{test},             required => 1 );
has test_exclude     => ( is => 'ro', isa => $TYPE{test_exclude},     required => 1 );
has profile          => ( is => 'ro', isa => $TYPE{profile},          required => 1 );
has enable           => ( is => 'ro', isa => $TYPE{enable},           required => 1 );
has disable          => ( is => 'ro', isa => $TYPE{disable},          required => 1 );
has equivalence      => ( is => 'ro', isa => $TYPE{equivalence},      required => 1 );
has coverage         => ( is => 'ro', isa => $TYPE{coverage},         required => 1 );
has timeout_factor   => ( is => 'ro', isa => $TYPE{timeout_factor},   required => 1 );
has timeout_floor    => ( is => 'ro', isa => $TYPE{timeout_floor},    required => 1 );
has baseline_timeout => ( is => 'ro', isa => $TYPE{baseline_timeout}, required => 1 );
has in_place         => ( is => 'ro', isa => $TYPE{in_place},         required => 1 );
has link             => ( is => 'ro', isa => $TYPE{link},             required => 1 );
has keep_work        => ( is => 'ro', isa => $TYPE{keep_work},        required => 1 );
has mutant           => ( is => 'ro', isa => $TYPE{mutant},           required => 1 );
has since            => ( is => 'ro', isa => $TYPE{since},            required => 1 );
has shard            => ( is => 'ro', isa => $TYPE{shard},            required => 1 );
has cache            => ( is => 'ro', isa => $TYPE{cache},            required => 1 );
has cache_dir        => ( is => 'ro', isa => $TYPE{cache_dir},        required => 1 );

1;

__END__

=head1 NAME

Test::Mutation::Config - the settings of a run

=head1 SYNOPSIS

    my $config = Test::Mutation::Settings::of_call( { root => $directory, jobs => 4 } );
    say $config->jobs;

=head1 DESCRIPTION

A configuration is an immutable value with one attribute for each setting of L<Test::Mutation::Settings>.
Each attribute has the type of its setting and the name of the setting in a call of the library.
L<Test::Mutation::Settings/resolve> builds every configuration, and the table there states the meaning and the default of each value.

=head1 ATTRIBUTES

=head2 root

The project directory, with its full path.

=head2 config

The name of the configuration file that the run read, or nothing.

=head2 jobs

The number of test processes that run side by side.

=head2 min_score

The score below which the run fails, or nothing.

=head2 format

The reports to write.

=head2 report_dir

The directory of the report files.

=head2 threshold_high, threshold_low

The scores from which a report marks the result as good and below which it marks it as poor.

=head2 perl

The interpreter that runs the tests.

=head2 switch

Switches for the interpreter, C<-Ilib> by default.
The run names a relative directory after C<-I> in full, as C<prove> does, so a test may change its directory.

=head2 source, source_exclude

Glob patterns for the files to mutate and for the files to leave out.

=head2 test, test_exclude

Glob patterns for the test files and for the test files to leave out.

=head2 profile, enable, disable

The mutator profile and the names added to or removed from it.

=head2 equivalence

Whether the run compares the compiled code of an undetected mutant with the original.
A mutant that compiles to the same code is ignored, and so is a mutant with the code of an earlier undetected mutant.

=head2 coverage

C<line> selects tests by the lines they ran, C<file> by the files they loaded.

=head2 timeout_factor, timeout_floor

A test may run for the larger of the floor in seconds and the factor times its unmodified duration.

=head2 baseline_timeout

The time limit in seconds for a test in the unmodified run.

=head2 in_place, link

The tests run in copies of the project, which a run makes in the temporary directory.
C<in_place> runs them in the project itself.
C<link> names the paths that a copy holds as links to the original.

=head2 keep_work

Whether the run keeps its work directory.

=head2 mutant

Mutant identifiers; when set, the run covers these mutants.

=head2 since

A Git revision; when set, the run covers the lines changed since it.

=head2 shard

A part of the mutants as C<K/N>; the run covers every Nth mutant, starting at the Kth.
N runs with K from 1 to N cover every mutant once.

=head2 cache

Whether the run reuses results from C<cache.json> in the cache directory and writes its own.
The key of a result covers the mutated file, the tests that reach the mutant, and the analyzed source files those tests load.
The key also covers every other file under the top-level directories of the sources and the tests, so a change there measures every mutant again.
A change outside those directories, such as a new version of a dependency, needs a run without the cache.

=head2 cache_dir

The directory of the cache and of the work of a run.

=cut
