package Test::Mutation::Environment;
use v5.36;
use Types::Standard qw(ArrayRef Dict Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my @variables = (
    [ PATH              => 'Looks up the selected Perl interpreter and programs invoked by the tests.' ],
    [ PERL5LIB          => 'Adds library directories inherited by Perl processes.' ],
    [ PERL5OPT          => 'Supplies inherited interpreter switches before the measurement shim loads.' ],
    [ PERL_DL_NONLAZY   => 'Requests eager XS symbol resolution for a build-library test.' ],
    [ HARNESS_ACTIVE    => 'Identifies a child test started by the harness.' ],
    [ HARNESS_VERSION   => 'Gives child tests the installed TAP harness version.' ],
    [ HARNESS_RULESFILE => 'Selects the TAP harness scheduling rules for parallel and sequential tests.' ],
    [ TMPDIR   => 'Selects the temporary parent and points each running test at its private temporary directory.' ],
    [ TMP      => 'Can select the temporary parent on platforms where File::Spec reads TMP.' ],
    [ TEMP     => 'Can select the temporary parent on platforms where File::Spec reads TEMP.' ],
    [ PWD      => 'Names the working directory of the child test.' ],
    [ NO_COLOR => 'Disables color when its value is nonempty.' ],
    [ GITHUB_ACTIONS           => 'Enables GitHub annotations by default when its value is true.' ],
    [ GITHUB_STEP_SUMMARY      => 'Receives the Markdown report for the current GitHub Actions step.' ],
    [ TEST_MUTATION_ROOT       => 'Identifies the measured project inside a running test.' ],
    [ TEST_MUTATION_GENERATION => 'Selects the shim generation for a nested measurement.' ],
    [
        TEST_MUTATION_COMPILER_INPUTS =>
          'The driver sets the path where a standalone Perl compiler records additional library inputs.'
    ],
    [ TEST_MUTATION_COMPILER_READS => 'Names the file operands that the target Perl resolves during compilation.' ],
    [ TEST_MUTATION_SPEC           => 'Names the measurement instructions for the unnumbered shim.' ],
    [ TEST_MUTATION_RECORD         => 'Names the process record directory for the unnumbered shim.' ],
    [ TEST_MUTATION_SPEC_Gn        => 'Names the measurement instructions for shim generation n.' ],
    [ TEST_MUTATION_RECORD_Gn      => 'Names the process record directory for shim generation n.' ],
    [ PERL_HASH_SEED               => 'The compiler comparison uses a fixed seed for reproducible deparsing.' ],
    [ PERL_PERTURB_KEYS            => 'The compiler comparison uses a fixed hash traversal mode.' ],
    [ OLDPWD                       => 'The previous shell working directory is excluded from the cache key.' ],
    [ SHLVL                        => 'The shell nesting level is excluded from the cache key.' ],
    [ '_'                          => 'The previous shell command is excluded from the cache key.' ],
    map { [ $_, 'The cache key excludes the value assigned by the runner.' ] }
      qw(GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_RUN_ATTEMPT RUNNER_TEMP RUNNER_TRACKING_ID CI_JOB_ID CI_PIPELINE_ID)
);

signature_for rows => ( positional => [], returns => ArrayRef [ Dict [ name => Str, meaning => Str ] ] );

sub rows () {
    return [ map { { name => $_->[0], meaning => $_->[1] } } @variables ];
}

1;

__END__

=head1 NAME

Test::Mutation::Environment - describe the environment of a measurement

=head1 FUNCTIONS

=head2 rows

Returns the variable names and their roles in a measurement.
A lowercase n in a variable name represents the positive integer assigned to the shim generation.

=cut
