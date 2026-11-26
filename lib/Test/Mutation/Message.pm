package Test::Mutation::Message;
use v5.36;
use Moo;
use Types::Standard qw(ArrayRef Enum HashRef InstanceOf Slurpy Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

# Each row: the identifier, the kind, the text with its slots, and the description for the manual.
my @ROWS = (
    [
        'build-recipe-missing',
        'usage',
        'XS sources need Makefile.PL or Build.PL; build the distribution separately and use -C to select its build directory',
        'An XS distribution needs a configuration script in its source directory.'
    ],
    [
        'build-product-stale', 'usage',
        '{path} needs a rebuild; run {command} before in-place measurement',
        'An in-place build product predates its source.'
    ],
    [
        'build-copy-not-updated', 'environment',
        '{path} in the private build did not update after changing {source}',
        'The generated product kept its original contents after the mutant was installed.'
    ],
    [
        'build-command-failed',       'environment',
        '{command} failed: {reason}', 'A command that builds the private distribution failed.'
    ],
    [
        'command-unknown', 'usage',
        'unknown command {command}, did you mean {nearest}?',
        'The first word or the command named in help has no matching command.'
    ],
    [
        'in-place-observation', 'warning',
        '--in-place uses the module hook, which can miss absolute paths and child processes',
        'A project run reports the observation limits of its module hook.'
    ],
    [
        'path-selector-invalid', 'usage',
        'invalid path selection {path}: {reason}',
        'A path operand must name a project source or directory and use positive, ascending line ranges.'
    ],
    [
        'argument-unexpected',            'usage',
        'unexpected argument {argument}', 'The command line holds an operand, and the command takes none.'
    ],
    [
        'show-without-identifier',        'usage',
        'show needs a mutant identifier', 'The command line of show names no mutant.'
    ],
    [
        'exec-without-command', 'usage',
        'exec needs a mutant identifier and a command',
        'The command line of exec names no mutant or no command to run.'
    ],
    [
        'merge-without-report',                 'usage',
        'merge needs the report of every part', 'The command line of merge names no report file.'
    ],
    [
        'directory-closed', 'usage',
        'cannot enter {directory}: {reason}',
        'The directory that --root names is absent, is no directory, or refuses the user.'
    ],
    [
        'mutant-unknown', 'usage',
        'no mutant has the identifier {identifier}',
        'No mutant of the project has an identifier that starts with the given text.'
    ],
    [
        'mutant-ambiguous', 'usage',
        'more than one mutant has the identifier {identifier}',
        'Several mutants have an identifier that starts with the given text.'
    ],
    [ 'mutator-unknown', 'usage', 'unknown mutator: {names}', 'A setting names a mutator that the tool lacks.' ],
    [
        'prove-exec-unsupported',
        'usage',
        '.proverc: --exec replaces the Perl interpreter needed to measure mutants',
        'The project requests an external test executor in its prove configuration.'
    ],
    [
        'glob-unmatched', 'usage',
        '{setting} pattern "{pattern}" matches no project file',
        'An explicitly supplied include or exclude pattern must match a file in the project.'
    ],
    [
        'interpreter-invalid', 'usage',
        'cannot use "{program}" as the Perl interpreter',
        'The selected program must report Perl 5.10 or later to load the test shim.'
    ],
    [
        'revision-unknown', 'usage',
        'no commit matches revision "{revision}"',
        'The revision passed to --since must identify a commit in the project repository.'
    ],
    [
        'source-changed', 'environment',
        '{path} changed after analysis',
        'The bytes of the copied source differ from the bytes used to generate its mutants.'
    ],
    [
        'option-unknown', 'usage',
        '{option} names no option; the nearest is {nearest}',
        'The command line holds an option that the command lacks, and the message names the option nearest to it.'
    ],
    [
        'option-elsewhere',                   'usage',
        '{option} is no option of {command}', 'The command line holds an option of another command.'
    ],
    [
        'option-without-value', 'usage',
        '{option} needs a value',
        'An option that takes a value stands at the end of the command line or before an option.'
    ],
    [
        'option-with-value',       'usage',
        '{option} takes no value', 'An option that is on or off has a value after an equals sign.'
    ],
    [
        'setting-unknown', 'usage',
        '{setting} names no setting; the nearest is {nearest}',
        'The configuration file or a call of the library names a setting that the tool lacks.'
    ],
    [
        'setting-invalid', 'usage',
        '{setting} takes {expects}, not {value}',
        'A setting has a value outside its type, which the message states as the user wrote it.'
    ],
    [
        'setting-outside-file', 'usage',
        '{setting} names the place of the file, so the file cannot hold it',
        'The configuration file holds the directory of the project or the name of a configuration file.'
    ],
    [
        'config-section', 'usage',
        '{file}: [{section}] is a section, and the file holds none',
        'The configuration file holds a table, and its settings stand at its top level.'
    ],
    [
        'settings-out-of-order',       'usage',
        '{first} lies above {second}', 'The low threshold of the reports lies above the high one.'
    ],
    [
        'settings-exclusive',                      'usage',
        '{first} and {second} exclude each other', 'Two settings that the user set cannot hold in one run.'
    ],
    [
        'working-directory-gone', 'usage',
        'the working directory is gone, so --root must name the project',
        'The process stands in a directory that no longer exists, and the command line names no project.'
    ],
    [
        'input-unreadable', 'usage',
        'cannot read {path}: {reason}',
        'A file that the user names, such as the configuration file or a report, cannot be read.'
    ],
    [
        'input-malformed', 'usage',
        '{path}: {reason}',
        'A file that the user names holds a text that the tool cannot use, for the reason that follows its name.'
    ],
    [ 'merge-empty', 'usage', 'merge needs at least one report', 'A merge got no report.' ],
    [
        'merge-repeated-mutant',                     'usage',
        'mutant {id} appears in more than one part', 'Two reports of a merge hold the same mutant.'
    ],
    [
        'merge-part-size', 'usage',
        '{name} holds {held} mutants, and part {part} of {parts} has {expected}',
        'A report of a merge holds another number of mutants than its part of the run has.'
    ],
    [
        'merge-whole-run',                                    'usage',
        '{name} is the report of a whole run, not of a part', 'A report of a merge comes from a run without --shard.'
    ],
    [
        'merge-without-inventory',   'usage',
        '{name} names no inventory', 'A report of a merge lacks the count and the digest of the mutants of its run.'
    ],
    [
        'merge-failed-baseline', 'usage',
        '{name} has failing tests in its unmodified run, so its part measured nothing',
        'A report of a merge comes from a part whose tests fail without a mutant.'
    ],
    [
        'merge-other-split', 'usage',
        '{first} holds part {first_part} of {first_parts}, and {name} holds part {part} of {parts}',
        'Two reports of a merge come from runs that split the mutants into different numbers of parts.'
    ],
    [
        'merge-other-mutants',                      'usage',
        '{name} covers other mutants than {first}', 'Two reports of a merge come from runs over different mutants.'
    ],
    [
        'merge-repeated-part',
        'usage',
        '{first} and {name} both hold part {part} of {parts}',
        'Two reports of a merge hold the same part of the run.'
    ],
    [
        'merge-missing-part',                'usage',
        'part {part} of {parts} is missing', 'The reports of a merge lack one part of the run.'
    ],
    [
        'merge-missing-parts',                 'usage',
        'parts {list} of {parts} are missing', 'The reports of a merge lack several parts of the run.'
    ],
    [
        'report-not-json',              'usage',
        'the text is no JSON document', 'A report file holds a text that is no JSON object.'
    ],
    [
        'report-without-facts', 'usage',
        'the report holds no facts of a mutation run',
        'A report file is a JSON document that this tool did not write.'
    ],
    [
        'report-invalid-value', 'usage',
        'the report is malformed: no valid value at {place}',
        'A value of a report file has another type than the report format gives it.'
    ],
    [
        'report-malformed',                  'usage',
        'the report is malformed: {reason}', 'A report file holds facts that form no result of a run.'
    ],
    [
        'report-location-outside', 'usage',
        'the report is malformed: a location lies outside the source of {path}',
        'A mutant of a report file starts or ends outside the text of its source file.'
    ],
    [
        'report-location-reversed', 'usage',
        'the report is malformed: a location ends before its start in {path}',
        'A mutant of a report file ends before it starts.'
    ],
    [
        'suppressions-invalid', 'usage',
        'invalid suppression comments: {list}',
        'Comments of the analyzed files break the grammar of the suppression comments or suppress no mutant.'
    ],
    [
        'suppression-malformed', 'usage',
        '{path}:{line}: "{comment}" differs from the grammar',
        'A comment resembles a suppression comment and has another form than the grammar.'
    ],
    [
        'suppression-mutator-unknown',            'usage',
        '{path}:{line}: unknown mutator {names}', 'A suppression comment names a mutator that the tool lacks.'
    ],
    [
        'suppression-end-unopened', 'usage',
        '{path}:{line}: ## use mutate ends no open block',
        'A comment ends a block of suppressed lines that no comment opened.'
    ],
    [
        'suppression-block-nested', 'usage',
        '{path}:{line}: ## no mutate opens a block inside the block of line {open}',
        'A comment opens a block of suppressed lines while an earlier block is still open.'
    ],
    [
        'suppression-block-unclosed',
        'usage',
        '{path}:{line}: ## no mutate opens a block that no ## use mutate ends',
        'A block of suppressed lines is still open at the end of its file.'
    ],
    [
        'suppression-sub-missing', 'usage',
        '{path}:{line}: ## no mutate sub stands before no named subroutine or method',
        'The statement after a comment that suppresses a subroutine is no named subroutine or method.'
    ],
    [
        'suppression-unused', 'usage',
        '{path}:{line}: "{comment}" suppresses no mutant',
        'A suppression comment covers no mutant that a mutator of the tool makes.'
    ],
    [
        'suppression-names-missing',
        'usage',
        '{path}:{line}: "{comment}" names no mutator, and suppress-require-names asks for one',
        'A suppression comment names no mutator, and the setting suppress-require-names asks for a name.'
    ],
    [
        'suppression-reason-missing',
        'usage',
        '{path}:{line}: "{comment}" gives no reason, and suppress-require-reason asks for one',
        'A suppression comment gives no reason, and the setting suppress-require-reason asks for one.'
    ],
    [
        'file-unreadable',              'environment',
        'cannot read {path}: {reason}', 'A file or a directory of the project or of the run cannot be read.'
    ],
    [
        'file-unwritable',               'environment',
        'cannot write {path}: {reason}', 'A file of the run or of a report cannot be written.'
    ],
    [
        'file-unclosable',               'environment',
        'cannot close {path}: {reason}', 'A file reports an error when it closes, so its content may be incomplete.'
    ],
    [
        'file-unrenamable',               'environment',
        'cannot rename {path}: {reason}', 'A file that the tool wrote cannot take its final name.'
    ],
    [
        'file-unremovable',               'environment',
        'cannot remove {path}: {reason}', 'A file or a directory of a copy cannot be removed.'
    ],
    [ 'file-unlinkable', 'environment', 'cannot link {path}: {reason}', 'A copy of the project cannot hold a link.' ],
    [
        'file-uncopyable',                            'environment',
        'cannot copy {source} to {target}: {reason}', 'A file of the project cannot be copied.'
    ],
    [
        'file-time-unsettable',                    'environment',
        'cannot set the time of {path}: {reason}', 'A copied file cannot take the time of its original.'
    ],
    [
        'file-mode-unsettable',                    'environment',
        'cannot set the mode of {path}: {reason}', 'A copied file or directory cannot take the mode of its original.'
    ],
    [ 'directory-missing', 'environment', 'cannot read {path}: no such directory', 'The directory to copy is absent.' ],
    [
        'directory-uncreatable',          'environment',
        'cannot create {path}: {reason}', 'A directory of the run, of a copy, or of a report cannot be created.'
    ],
    [
        'directory-unopenable',         'environment',
        'cannot open {path}: {reason}', 'A directory of a copy refuses the rights that the tool needs to change it.'
    ],
    [
        'project-uncopyable', 'environment',
        'cannot copy the project: {reason}; --in-place runs the tests in the project itself',
        'The copy of the project that the tests run in cannot be made.'
    ],
    [ 'git-unstartable', 'environment', 'cannot start git: {reason}', 'The git program cannot be started.' ],
    [
        'git-failed',                     'environment',
        'git {command} failed: {reason}', 'A git command failed, with the first line of its error.'
    ],
    [ 'git-silent', 'environment', 'git {command} failed', 'A git command failed and left no error to read.' ],
    [
        'process-unstartable',              'environment',
        'cannot start a process: {reason}', 'The system refuses a new process for a test.'
    ],
    [
        'pipe-unopenable',              'environment',
        'cannot open a pipe: {reason}', 'The system refuses the pipe that carries the output of a test.'
    ],
    [
        'pipe-unclosable', 'environment',
        'cannot close a pipe: {reason}',
        'The pipe that carries the output of a test reports an error when it closes.'
    ],
    [
        'test-directory-closed', 'environment',
        'cannot run the test in {directory}: {reason}',
        'The process of a test cannot enter the directory that the test runs in.'
    ],
    [
        'test-streams-unset',                           'environment',
        'cannot set the streams of the test: {reason}', 'The process of a test cannot open its standard streams.'
    ],
    [
        'command-unstartable',              'environment',
        'cannot start {command}: {reason}', 'The interpreter of the tests cannot be started.'
    ],
    [
        'command-not-runnable',           'environment',
        'cannot run {command}: {reason}', 'The command of mutation exec exists, and the system refuses to run it.'
    ],
    [
        'command-not-found', 'environment',
        'cannot find {command}: {reason}',
        'No program of the name that mutation exec runs exists at its path or on the search path.'
    ],

    # The shim runs on Perl 5.10 without the catalog, so it holds a copy of the line of each of these two messages.
    [
        'spec-unreadable', 'environment',
        'cannot read spec {path}: {reason}',
        'A test process cannot read the file that names the mutants and the lines of its run.'
    ],
    [
        'spec-unclosable', 'environment',
        'cannot close spec {path}: {reason}',
        'A test process reports an error when it closes the file that names the mutants and the lines of its run.'
    ],
    [
        'analysis-left-out-place', 'warning',
        '{path}: the analysis left out 1 place, which has no mutant',
        'The analysis of a file left one place out, so the code there has no mutant.'
    ],
    [
        'analysis-left-out-places', 'warning',
        '{path}: the analysis left out {count} places, which have no mutant',
        'The analysis of a file left several places out, so the code there has no mutant.'
    ],
    [
        'work-directory-stays',
        'warning',
        'the work directory {path} stays, because a file in it resists removal',
        'A test left a file in the work directory that the run cannot remove.'
    ],
    [ 'tests-unmatched', 'warning', 'no test files match', 'The project has mutants and no test file to run.' ],
    [
        'tests-conflict', 'warning',
        'the tests fail when they run side by side, so the mutants run one test at a time',
        'The tests pass one at a time and fail side by side, so the run gives up the parallel jobs.'
    ],
    [
        'conflicting-test', 'warning',
        '{test} passed alone after an overlapping failure, so later invocations run one at a time',
        'The isolated repeat passed after simultaneous invocations of the same test interfered.'
    ],
    [
        'loaded-around-hook', 'warning',
        '{test} loads {path} around the hook and cannot detect its mutants',
        'A test reads a source file in a way that passes by the module that places the mutants.'
    ],
    [
        'project-changed', 'warning',
        'the project changed while the mutants ran: {changes}',
        'A mutant test changed the project in place and the runner restored the affected paths.'
    ],
    [
        'decompiled-code-unstable',
        'warning',
        '{path}: Perl decompiles the file to no stable text, so the run compares no compiled code of the file',
        'Two decompilations of a file differ, so no mutant of the file counts as equal to the original code.'
    ],
    [
        'syntax-check-failed',
        'warning',
        '{path} does not pass a standalone syntax check, so its load failures count as compile errors',
        'A source file fails a syntax check of its own, so a mutant that fails to load counts as a compile error.'
    ],
    [
        'internal-error',         'internal',
        'internal error: {text}', 'An error that the tool did not foresee ended the command.'
    ],
    [
        'message-slots', 'internal',
        'the message {id} takes the slots {expected}, and the call gives {given}',
        'The code asks for a message with other values than its text holds.'
    ],
    [
        'class-argument-unknown', 'internal',
        'the class {class} takes no argument {names}',
        'The code builds a value with an argument that names none of its attributes.'
    ],
    [
        'shim-unprepared',
        'internal',
        'cannot prepare the shim for generation {generation}',
        'The text of the shim lacks the lines that a run rewrites.'
    ],
    [ 'shim-missing', 'internal', 'cannot find {file}', 'The module search path holds no file of the shim.' ],
    [
        'verdict-without-syntax-check',
        'internal',
        'a load failure needs a syntax check',
        'The verdict of a mutant got a failed load without the result of its syntax check.'
    ],
    [
        'below-gate', 'below-gate',
        'the score {score}% is below the gate of {gate}%',
        'The run measured a score below the one that --min-score asks for.'
    ],
    [
        'baseline-failed', 'baseline-failed',
        'tests that fail without a mutant: {failed}',
        'Tests fail in the unmodified run, so the run measured no mutant.'
    ],
    [
        'inconclusive',            'inconclusive',
        'the run states no score', 'The run ended without a score that the user can rely on.'
    ],
    [
        'interrupted',                'interrupted',
        'interrupted by SIG{signal}', 'A signal ended the command before its work was done.'
    ],
);
my $ID      = Enum [ map { $_->[0] } @ROWS ];
my $WARNING = Enum [ map { $_->[0] } grep { $_->[1] eq 'warning' } @ROWS ];

has id => ( is => 'ro', isa => $ID, required => 1 );
has kind => (
    is       => 'ro',
    isa      => Enum [qw(usage environment warning internal below-gate baseline-failed inconclusive interrupted)],
    required => 1
);
has text        => ( is => 'ro', isa => Str, required => 1 );
has description => ( is => 'ro', isa => Str, required => 1 );

my @CATALOG =
  map { __PACKAGE__->new( id => $_->[0], kind => $_->[1], text => $_->[2], description => $_->[3] ) } @ROWS;
my %ROW = map { $_->id => $_ } @CATALOG;

signature_for rows => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Message'] ] );

sub rows () {
    return [@CATALOG];
}

signature_for row => ( positional => [$ID], returns => InstanceOf ['Test::Mutation::Message'] );

sub row ($id) {
    return $ROW{$id};
}

sub _filled ( $text, $values ) {
    return $text =~ s/[{](\w+)[}]/$values->{$1}/gr;
}

signature_for text_of => ( positional => [ $ID, Slurpy [ HashRef [Str] ] ], returns => Str );

sub text_of ( $id, $values ) {
    my $text = $ROW{$id}->text;
    my ( $expected, $given ) = map { join( q{ }, sort $_->@* ) || 'none' } [ $text =~ /[{](\w+)[}]/g ],
      [ keys $values->%* ];
    die _filled( Test::Mutation::Message::row('message-slots')->text,
        { id => $id, expected => $expected, given => $given } )
      . "\n"
      if $expected ne $given;
    return _filled( $text, $values );
}

signature_for warning => ( positional => [ $WARNING, Slurpy [ HashRef [Str] ] ], returns => Str );

sub warning ( $id, $values ) {
    return Test::Mutation::Message::text_of( $id, $values->%* );
}

signature_for line => ( positional => [Str], returns => Str );

sub line ($text) {
    return "mutation: $text\n";
}

1;

__END__

=head1 NAME

Test::Mutation::Message - the catalog of the messages of a failure or a warning

=head1 SYNOPSIS

    say Test::Mutation::Message::text_of( 'mutant-unknown', identifier => 'zzzz' );
    say Test::Mutation::Message::warning( 'syntax-check-failed', path => 'lib/Calc.pm' );

    for my $message ( Test::Mutation::Message::rows()->@* ) {
        printf "%s (%s): %s\n", $message->id, $message->kind, $message->description;
    }

=head1 DESCRIPTION

The catalog states every text that the tool gives for a failure or a warning, each once.
A text holds a slot such as C<{path}> where a call puts a value.
No other place of the library holds the words of a failure or a warning, so a reader finds every message here.

=head1 FUNCTIONS

=head2 rows

Returns a L<Test::Mutation::Message> for every message, in the order of the catalog.

=head2 row

    my $message = Test::Mutation::Message::row('file-unreadable');

Returns the message with the given identifier.

=head2 text_of

    my $text = Test::Mutation::Message::text_of( 'directory-closed', directory => $name, reason => "$!" );

Returns the text of a message with a value in each slot.
The call names every slot of the text and no other one, and the function dies when it names others.

=head2 warning

    push @warnings, Test::Mutation::Message::warning( 'loaded-around-hook', test => 't/a.t', path => 'lib/A.pm' );

Returns the text of a message of the kind C<warning>, which a run lists in its result.
It refuses the identifier of every other kind, so a warning never takes the words of a failure.

=head2 line

    print {*STDERR} Test::Mutation::Message::line($text);

Returns the text as a line of the command: the name of the command, the text, and a newline.

=head1 ATTRIBUTES

=head2 id

The identifier of the message, lowercase words with hyphens between them.

=head2 kind

What the message states about the command.
C<usage> and C<environment> are the kinds of a L<Test::Mutation::Error>.
C<warning> marks a fact of a run that the report lists and that ends no command.
C<internal> marks a defect of the tool.
C<below-gate>, C<baseline-failed>, C<inconclusive>, and C<interrupted> mark the line that ends a run with that outcome.
Every kind apart from C<warning> and C<interrupted> is the name of a row of L<Test::Mutation::Exit>, which gives the exit status.

=head2 text

The words of the message, with a name in braces for each value.

=head2 description

One sentence for the manual that tells when the message appears.

=cut
