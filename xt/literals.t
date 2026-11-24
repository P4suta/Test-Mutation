use v5.36;
use Test2::V0;
use lib 't/lib', 't/contract/lib', 't/e2e/lib';
use Gate;
use Library;
use Sources;
use Space;
use Test::Mutation::Status;

# The messages, the lists of statuses, and the variables of the environment each belong in one table.
# No such table holds them yet, so the scan states where they stand in the code, and each place is an open finding.

my $value = "\x{2026}";

subtest 'the scan rejects a message that a die statement holds' => sub {
    is Sources::messages("sub f { die \"cannot read \$path: \$!\\n\" if !\$ok; die \$error; }\n"),
      ["cannot read $value: $value"],
      'a message with two values, and no message for an error that the code passes on';
    is Sources::messages("die 'unknown mutator: ' . join( ', ', \@unknown ) . \"\\n\" if \@unknown;\n"),
      ["unknown mutator: $value"],
      'a message in pieces';
    is Sources::messages("die Test::Mutation::Interrupted->new( signal => \$signal ) if \$signal;\n"), [],
      'an exception object';
    is Sources::messages("my %count = ( die => 1 );\n\$self->die('gone');\n# die 'in a comment'\n"), [],
      'a key, a method, and a comment';
    is Sources::messages( "_warn( \$run, 'no test files match' ) if \$none;\nsub _warn { return }\n", '_warn' ),
      ['no test files match'], 'a message that a named subroutine reports';
    like 'cannot read ci.toml: No such file', Sources::pattern("cannot read $value: $value"),
      'a message matches its text';
    unlike 'cannot write ci.toml: full', Sources::pattern("cannot read $value: $value"), 'and no other text';
};

subtest 'the scan rejects a list of statuses outside the table' => sub {
    my @names = qw(Killed Survived NoCoverage);
    is Sources::lists_of(
        "my \@all = qw(Killed Survived);\nmy %undetected = ( Survived => 1, NoCoverage => 1 );\n", \@names
      ),
      2,
      'a list of words and the keys of a hash';
    is Sources::lists_of( "my \@counted = ( [ Killed => 'killed' ], [ Survived => 'survived' ] );\n", \@names ), 1,
      'a list of pairs counts once';
    is Sources::lists_of( "sub tally (\$c) { my \$valid = \$c->{Killed} + \$c->{Survived}; return \$valid }\n",
        \@names ), 1,
      'a formula over two statuses';
    is Sources::lists_of( "return 'Killed' if \$failed;\nreturn 'Survived';\n# Killed, Survived\n", \@names ), 0,
      'one status in each statement, and a comment';
};

subtest 'the scan rejects a variable of the environment that the code names' => sub {
    my $code = "my \$a = \$ENV{GITHUB_ACTIONS};\nlocal \$ENV{TMPDIR} = \$t;\nmy \$b = \$ENV{ name() };\n"
      . "my \$c = \$world->{env}{NO_COLOR};\nmy \$d = \$env->{CI};\n# \$ENV{IN_A_COMMENT}\n";
    is Sources::environment($code), [qw(CI GITHUB_ACTIONS NO_COLOR TMPDIR a-computed-name)],
      'a read, a local value, a computed name, and the environment of a world';
    is Sources::environment("my %env = ( PATH => 1 );\nmy \$text = 'ENV';\n"), [], 'no use of the environment';
};

my @files  = ( 'bin/mutation', Library::modules()->@* );
my %code   = map { $_ => Sources::slurp($_) } @files;
my $manual = join q{}, map { Sources::documentation( $code{$_} )->{text} } 'bin/mutation', 'lib/Test/Mutation.pm';
like $manual, qr/^=head1 CONFIGURATION$/m, 'the manual is the documentation of the command and of the main module';

# literal: no die statement holds the text of its message.
my ( @literal, $messages );
for my $file (@files) {
    my $count = Sources::messages( $code{$file} )->@* or next;
    $messages += $count;
    push @literal, "$file: $count die statements hold their message";
}
Gate::findings( 'contract-literal-source', \@literal );
Gate::checked( 'die statements with a message', $messages, at_least => 80 );

# status-once: no list of statuses stands outside the table of the statuses.
my @names = map { $_->name } Test::Mutation::Status::rows()->@*;
my ( @lists, $lists );
for my $file ( grep { $_ ne 'lib/Test/Mutation/Status.pm' } @files ) {
    my $count = Sources::lists_of( $code{$file}, \@names ) or next;
    $lists += $count;
    push @lists, "$file: $count lists of statuses";
}
Gate::findings( 'contract-status-once-source', \@lists );
Gate::checked( 'lists of statuses', $lists, at_least => 9 );

# env: every variable of the environment that the code uses stands in a table, and the manual lists it.
my ( @unlisted, %variable );
for my $file (@files) {
    for my $name ( Sources::environment( $code{$file} )->@* ) {
        $variable{$name} = 1;
        push @unlisted, [ 'no table and no manual lists the variable', $name, $file ] if $manual !~ /\b\Q$name\E\b/;
    }
}
Gate::findings( 'contract-env-source', Space::folded( \@unlisted, 'variables', 'files' ) );
Gate::checked( 'variables of the environment',         scalar( keys %variable ), at_least => 5 );
Gate::checked( 'files of the library and the command', scalar @files,            at_least => 39 );

done_testing;
