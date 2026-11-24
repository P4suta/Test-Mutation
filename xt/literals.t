use v5.36;
use Test2::V0;
use lib 't/lib', 't/contract/lib', 't/e2e/lib';
use Gate;
use Library;
use Sources;
use Space;
use Test::Mutation::Message;
use Test::Mutation::Status;

# The messages, the lists of statuses, and the variables of the environment each belong in one table.
# The catalog holds the messages, so a die statement with words of its own is a violation.
# No table holds the statuses and the variables yet, so the scan states where they stand, and each place is an open finding.

my $value = "\x{2026}";

# The places that may copy the line of a message, compute the identifier of one, or catch an exception themselves.
# Each number is the exact count of the place, so one more of them is a violation too.
my %ALLOWED = (

    # The shim runs inside every test process, on Perl 5.10 and without the catalog, so it says each line itself.
    'lib/Test/Mutation/Shim.pm' => { copies => 1 },

    # raise hands the identifier of its caller on to the catalog, once for the text and once for the kind.
    'lib/Test/Mutation/Error.pm' => { computed => 2 },

    # The one place of the driver that catches an exception.
    'lib/Test/Mutation/Try.pm' => { eval => 1 },
);

# What is wrong with the calls that name a message: a name outside the catalog, a computed name, and a message without a call.
# `named` maps each file to the first arguments of its calls, and `computed` maps a file to the computed names it may hold.
sub named_problems ( $named, $catalog, $computed ) {
    my %known = map { $_ => 1 } $catalog->@*;
    my ( @problems, %used );
    for my $file ( sort keys $named->%* ) {
        my @literal = grep { $_ ne 'a-computed-identifier' } $named->{$file}->@*;
        my $count   = $named->{$file}->@* - @literal;
        $used{$_} = 1 for @literal;
        push @problems, "$file: $count calls compute the identifier of their message"
          if $count != ( $computed->{$file} || 0 );
        push @problems,
          map { "$file: a call names $_, which is no message of the catalog" } grep { !$known{$_} } @literal;
    }
    return @problems, map { "no call names the message $_" } grep { !$used{$_} } $catalog->@*;
}

# The line of each message as a die statement that copies it holds it: the name of the command, the words, and a mark for each value.
sub lines_of (@rows) {
    return map { ( Test::Mutation::Message::line( $_->text ) =~ s/\n\z//r =~ s/[{]\w+[}]/$value/gr ) => $_->id } @rows;
}

# The messages of a place that copies lines of the catalog: the identifier of each copy, and the words of every other message.
sub copied ( $messages, $lines ) {
    return [ map { $lines->{$_} } grep { defined $lines->{$_} } $messages->@* ],
      [ grep { !defined $lines->{$_} } $messages->@* ];
}

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

    is Sources::messages("open my \$in, '<', \$path or die \"cannot read \$path: \$!\\n\";\n"),
      ["cannot read $value: $value"], 'a message behind a failed call';
    is Sources::messages(
        "die( ( \@found ? 'more than one mutant has' : 'no mutant has' ) . \" the identifier \$id\\n\" );\n"),
      ["$value the identifier $value"], 'a message whose first words stand in a choice';
    is Sources::messages(
        "croak \"cannot write \$path\";\nCarp::confess('never');\nconfess 'a state that cannot be';\n"),
      [ "cannot write $value", 'a state that cannot be' ], 'a message that croak or confess raises';
    is Sources::messages(
        "my \$ok = eval { chdir \$dir or die \"chdir \$dir: \$!\\n\"; exec \@command or die \"exec \$command[0]: \$!\\n\" };\n"
      ),
      [ "chdir $value: $value", "exec $value: $value" ], 'the messages of a block that runs in another process';
    is Sources::messages( "die Test::Mutation::Message::text_of( 'shim-missing', file => \$file ) . \"\\n\";\n"
          . "Test::Mutation::Error::raise( 'file-unreadable', path => \$path, reason => \"\$!\" );\n" ),
      [], 'a text and an error that the catalog gives hold no words of their own';
};

subtest 'the scan rejects a call that names no message of the catalog' => sub {
    my $code =
        "Test::Mutation::Error::raise( 'file-unreadable', path => \$path, reason => \"\$!\" ) if !\$ok;\n"
      . "my \$text = Test::Mutation::Message::text_of(\$id);\nmy \$row = Test::Mutation::Message::row( q{inconclusive} );\n"
      . "open my \$in, '<', \$path or Test::Mutation::Error::raise( \"file-\$kind\", path => \$path );\n"
      . "my %raise = ( 'Test::Mutation::Error::raise' => 1 );\n# Test::Mutation::Error::raise('in-a-comment')\n";
    is Sources::identifiers($code),
      [ 'file-unreadable', 'a-computed-identifier', 'inconclusive', 'a-computed-identifier' ],
      'a literal identifier, a variable, another literal, and a text with a value';
    is Sources::identifiers("my \$handle = raise( 'x' );\n\$self->text_of('y');\n"), [],
      'a subroutine of another name names no message';
    is [
        named_problems(
            { 'lib/A.pm' => [ 'file-unreadable', 'file-unreadble', 'a-computed-identifier' ], 'lib/B.pm' => [] },
            [qw(file-unreadable file-unwritable)], {}
        )
      ],
      [
        'lib/A.pm: 1 calls compute the identifier of their message',
        'lib/A.pm: a call names file-unreadble, which is no message of the catalog',
        'no call names the message file-unwritable',
      ],
      'a name outside the catalog, a computed name, and a message that no code uses';
    is [
        named_problems(
            { 'lib/A.pm' => [ 'file-unreadable', 'a-computed-identifier' ] },
            ['file-unreadable'], { 'lib/A.pm' => 1 }
        )
      ],
      [], 'a place that the table allows to compute an identifier';
};

subtest 'the scan rejects a copy whose words differ from the line of the catalog' => sub {
    my %lines = lines_of( map { Test::Mutation::Message::row($_) } qw(spec-unreadable spec-unclosable) );
    is \%lines,
      {
        "mutation: cannot read spec $value: $value"  => 'spec-unreadable',
        "mutation: cannot close spec $value: $value" => 'spec-unclosable'
      },
      'the line of each message, with a mark for each value';
    my $code = "open my \$h, '<', \$p or die \"mutation: cannot read spec \$p: \$!\\n\";\n"
      . "close \$h or die \"mutation: cannot close the spec \$p: \$!\\n\";\ndie \"cannot read spec \$p: \$!\\n\";\n";
    is [ copied( Sources::messages($code), \%lines ) ],
      [ ['spec-unreadable'], [ "mutation: cannot close the spec $value: $value", "cannot read spec $value: $value" ] ],
      'a copy of a line, a copy with other words, and a copy without the name of the command';
};

subtest 'the scan rejects a place that catches an exception itself' => sub {
    is Sources::evals("my \$ok = eval { risky(); 1 };\nmy \$value = eval \$text;\n"), 2, 'a block and a text';
    is Sources::evals("my %kind = ( eval => 1 );\n\$object->eval;\nmy \@words = qw(do eval sub);\n# eval { }\n"), 0,
      'a key, a method, a word of a list, and a comment';
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
    is Sources::lists_of(
        "sub decide (\$failed) {\n    return 'Killed' if \$failed;\n    return 'Survived';\n}\n", \@names
      ),
      0,
      'a subroutine that names one status in each of its statements';
    is Sources::lists_of( "if (\$failed) { \$status = 'Killed' }\nelse { \$status = 'Survived' }\n", \@names ), 0,
      'a condition with one status in each branch';
    is Sources::lists_of( "my \$decide = sub (\$failed) { return 'Killed' if \$failed; return 'Survived' };\n",
        \@names ), 0,
      'a subroutine without a name';
    is Sources::lists_of( "my \$status = \$served ? { status => 'Survived' } : { status => 'NoCoverage' };\n",
        \@names ), 0,
      'a choice between two statuses is a decision, and so is a comparison with two';
    is Sources::lists_of( "if ( \$status eq 'Killed' || \$status eq 'Survived' ) { \$valid++ }\n", \@names ), 0,
      'a comparison with two statuses';
    is Sources::lists_of( "my %kept = map { \$_ => 1 } qw(Killed Survived);\n", \@names ), 1, 'a list behind a block';
    is Sources::lists_of( "my \@row = \$counts->\@{ 'Killed', 'Survived' };\n", \@names ), 1, 'the keys of a slice';
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

# literal: no die statement holds the text of its message, and every failure names a message of the catalog.
my @catalog = map { $_->id } Test::Mutation::Message::rows()->@*;
my %lines   = lines_of( Test::Mutation::Message::rows()->@* );
my ( @literal, %named, $calls, $copies );
for my $file (@files) {
    my $allowed  = $ALLOWED{$file} || {};
    my $messages = Sources::messages( $code{$file} );
    my ( $copied, $own ) = $allowed->{copies} ? copied( $messages, \%lines ) : ( [], $messages );
    my $evals   = Sources::evals( $code{$file} );
    my $calling = Sources::identifiers( $code{$file} );
    $named{$file} = [ $calling->@*, $copied->@* ];
    $calls  += $calling->@*;
    $copies += $copied->@*;
    push @literal, sprintf '%s: %d die statements hold their message', $file, scalar $own->@* if $own->@*;
    push @literal, "$file: $evals eval expressions catch an exception outside the one place of the driver"
      if $evals != ( $allowed->{eval} || 0 );
}
push @literal,
  named_problems( \%named, \@catalog,
    { map { $_ => $ALLOWED{$_}{computed} } grep { $ALLOWED{$_}{computed} } keys %ALLOWED } );
Gate::findings( 'contract-literal-source', \@literal );
Gate::checked( 'calls that name a message of the catalog',       $calls,          at_least => 99 );
Gate::checked( 'die statements that copy the line of a message', $copies,         at_least => 2 );
Gate::checked( 'messages of the catalog',                        scalar @catalog, at_least => 64 );

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
