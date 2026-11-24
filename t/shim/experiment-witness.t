use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file write_spec run_perl run_bare all_records lib_dir);

# Experiment E9: the witness, one statement at the start of the last top-level statement of a target file.
# It records from inside the file that the file compiled, so the record depends on no hook and on no load path.

# The statement as the plan writes it, for generation 1, index 17, and a fallback directory.
my $PLANNED = <<'PERL';
UNITCHECK{package DB;if(defined&Test::Mutation::Shim::G1::seen){Test::Mutation::Shim::G1::seen(17)}else{my($d)=(defined$ENV{TEST_MUTATION_RECORD_G1}?$ENV{TEST_MUTATION_RECORD_G1}:q{/tmp/fallback})=~/\A(.*)\z/s;if(CORE::open(my$h,q{>>},"$d/blind-$$.rec")){CORE::syswrite($h,"blind\t17\n");CORE::close($h)}}}
PERL

# The smallest change that records under every setting below.
# A key of a hash is never tainted, where a capture stays tainted under "use re 'taint'".
# A layer in the mode of the open replaces the layers that "use open" or -C would add.
my $AMENDED = <<'PERL';
UNITCHECK{package DB;if(defined&Test::Mutation::Shim::G1::seen){Test::Mutation::Shim::G1::seen(17)}else{my($d)=keys%{+{(defined$ENV{TEST_MUTATION_RECORD_G1}?$ENV{TEST_MUTATION_RECORD_G1}:q{/tmp/fallback}),1}};if(CORE::open(my$h,q{>>:raw},"$d/blind-$$.rec")){CORE::syswrite($h,"blind\t17\n");CORE::close($h)}}}
PERL
chomp $PLANNED;
chomp $AMENDED;

# The experiment takes a generation that no run around this test uses.
my $number   = 700 + ( $ENV{TEST_MUTATION_GENERATION} || 0 );
my $variable = "TEST_MUTATION_RECORD_G$number";

sub statement {
    my ( $template, $fallback ) = @_;
    ( my $text = $template ) =~ s/G1\b/G$number/g;
    $text =~ s{/tmp/fallback}{$fallback};
    return $text;
}

sub slurp {
    my ($path) = @_;
    open my $in, '<', $path or return q{};
    local $/ = undef;
    my $text = <$in>;
    close $in or die "close $path: $!";
    return defined $text ? $text : q{};
}

sub shown {
    my ($text) = @_;
    $text =~ s/\t/\\t/g;
    $text =~ s/\n/\\n/g;
    return $text;
}

sub blind_records {
    my ($dir) = @_;
    return join q{,}, map { shown( slurp($_) ) } sort glob "$dir/blind-*.rec";
}

# How a run ended, what it printed, the records of each directory, and the first line of its standard error.
sub summary {
    my ( $root, $run ) = @_;
    ( my $output = $run->{stdout} ) =~ s/\n+\z//;
    my ($error) = split /\n/, $run->{stderr};
    $error = q{} if !defined $error;
    $error =~ s/ at \S+ line \d+[.]\z//;
    return join q{ }, "exit=$run->{status}", 'output=' . shown($output), 'records=' . blind_records("$root/records"),
      'fallback=' . blind_records("$root/fallback"), "error=$error";
}

# A project with one target that holds the statement, as a module that a program loads or as the program itself.
sub target {
    my (%case)    = @_;
    my $root      = project();
    my $statement = statement( $case{template}, "$root/fallback" );
    my $pragmas   = join q{}, map { "$_\n" } @{ $case{pragmas} || [] };
    mkdir "$root/fallback" or die "mkdir: $!";

    # A replacement of open for every package, which a mock of the file system installs.
    write_file( "$root/lib/Replaced.pm",
        "package Replaced;\nBEGIN { *CORE::GLOBAL::open = sub { die \"a replacement of open ran\\n\" } }\n1;\n" );
    if ( $case{form} eq 'module' ) {
        write_file( "$root/lib/Seen/Module.pm",
            "package Seen::Module;\n${pragmas}sub value { return 41 }\n${statement}__PACKAGE__ eq 'Seen::Module';\n" );
        write_file( "$root/script.pl", "use Seen::Module;\nprint Seen::Module::value(), \"\\n\";\n" );
    }
    else {
        write_file( "$root/script.pl", "${pragmas}sub value { return 41 }\n${statement}print value(), \"\\n\";\n" );
    }
    return $root;
}

sub observed {
    my (%case)  = @_;
    my $root    = target(%case);
    my $records = "$root/" . ( $case{records} || 'records' );
    my $run     = run_bare(
        root  => $root,
        clear => $case{clear},
        env   => { $case{clear} ? () : ( $variable => $records ) },
        args  => [ '-Ilib', @{ $case{switches} || [] }, 'script.pl' ],
    );
    return summary( $root, $run );
}

my $RECORDED = 'exit=0 output=41 records=blind\t17\n fallback= error=';
my $FALLBACK = 'exit=0 output=41 records= fallback=blind\t17\n error=';
my $INSECURE = 'exit=255 output= records= fallback= error=Insecure dependency in open while running with -T switch';

# What syswrite does on a handle with a UTF-8 layer follows the interpreter.
# Perl 5.24 warns where the file turned warnings on, Perl 5.26 and 5.28 warn in every file, and Perl 5.30 refuses the call.
my $DEPRECATED = 'exit=0 output=41 records=blind\t17\n fallback= error=syswrite() is deprecated on :utf8 handles';
my $REFUSED    = q{exit=255 output= records= fallback= error=syswrite() isn't allowed on :utf8 handles};
my $ON_UTF8_HANDLE =
  $] >= 5.030 ? $REFUSED : $] >= 5.026 ? "$DEPRECATED. This will be a fatal error in Perl 5.30" : $RECORDED;
my $WITH_WARNINGS = $] >= 5.026 ? $ON_UTF8_HANDLE : $] >= 5.024 ? $DEPRECATED : $RECORDED;
my $utf8_range = $] >= 5.030 ? 'from 5.30' : $] >= 5.026 ? 'on 5.26 and 5.28' : $] >= 5.024 ? 'on 5.24' : 'before 5.24';

# The settings of a target file and of its process, with what the planned statement does in a module and in a program.
my @settings = (
    [ 'no pragma',               [],                                                 [],     $RECORDED, $RECORDED ],
    [ 'strict and warnings',     [ 'use strict;', 'use warnings;' ],                 [],     $RECORDED, $RECORDED ],
    [ 'fatal warnings',          [ 'use strict;', q{use warnings FATAL => 'all';} ], [],     $RECORDED, $RECORDED ],
    [ 'autodie',                 ['use autodie;'],                                   [],     $RECORDED, $RECORDED ],
    [ 'the -w switch',           [],                                                 ['-w'], $RECORDED, $RECORDED ],
    [ 'the -l switch',           [],                                                 ['-l'], $RECORDED, $RECORDED ],
    [ 'taint mode',              ['use strict;'],                                    ['-T'], $RECORDED, $RECORDED ],
    [ 'taint mode and re taint', [q{use re 'taint';}],                               ['-T'], $INSECURE, $INSECURE ],
    [ 'utf8 source',             ['use utf8;'],                                      [],     $RECORDED, $RECORDED ],
    [ 'utf8 handles',            [q{use open qw(:std :utf8);}],            [], $ON_UTF8_HANDLE, $ON_UTF8_HANDLE ],
    [ 'encoding handles',        [q{use open qw(:std :encoding(UTF-8));}], [], $ON_UTF8_HANDLE, $ON_UTF8_HANDLE ],
    [
        'utf8 handles and warnings',
        [ 'use warnings;', q{use open qw(:std :utf8);} ],
        [], $WITH_WARNINGS, $WITH_WARNINGS
    ],
    [ 'the -C switch',             [],          ['-CSDA'], $RECORDED, $ON_UTF8_HANDLE ],
    [ 'the newest feature bundle', ["use $];"], [],        $RECORDED, $RECORDED ],
);

for my $setting (@settings) {
    my ( $name, $pragmas, $switches, $in_module, $in_program ) = @{$setting};
    my %planned = ( module => $in_module, program => $in_program );
    for my $form (qw(module program)) {
        my %case = ( form => $form, pragmas => $pragmas, switches => $switches );
        my $does =
            $planned{$form} eq $RECORDED   ? 'records'
          : $planned{$form} =~ /\Aexit=0 / ? 'records and warns'
          :                                  'stops the program';
        my $when = $name =~ /handles|-C/ ? " $utf8_range" : q{};
        is observed( %case, template => $PLANNED ), $planned{$form},
          "E9: the planned statement in a $form under $name $does$when";
        is observed( %case, template => $AMENDED ), $RECORDED,
          "E9: the amended statement in a $form under $name records";
    }
}

sub shim_stub {
    return <<"PERL";
package Test::Mutation::Shim::G$number;
sub seen {
    my (\$log) = \$ENV{SEEN_LOG} =~ /\\A(.*)\\z/s;
    open my \$out, '>>', \$log or die "log: \$!";
    print {\$out} "seen\\t\$_[0]\\n";
    close \$out or die "close: \$!";
    return;
}
1;
PERL
}

# The lines that the tracer of the shim records for a target whose last statement starts with the given text.
sub line_trace {
    my ($prefix) = @_;
    my $root = project();
    mkdir "$root/blind" or die "mkdir: $!";
    ( my $start = $prefix ) =~ s{/tmp/fallback}{$root/blind};
    my $module = <<'PERL';
package Traced::Witness;
use strict;
use warnings;
my $loaded = 1;
sub value {
    return $loaded;
}
1;
STARTsub last_one {
    return 2;
}
PERL
    $module =~ s/^START/$start/m;
    write_file( "$root/lib/Traced/Witness.pm", $module );
    write_file( "$root/script.pl",
        "use Traced::Witness;\nprint Traced::Witness::value(), Traced::Witness::last_one(), \"\\n\";\n" );
    write_spec(
        "$root/spec",
        trace   => 1,
        targets => [ [ "$root/lib/Traced/Witness.pm", "$root/lib/Traced/Witness.pm" ] ]
    );
    my $run = run_perl(
        root => $root,
        env  =>
          { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records", $variable => "$root/blind" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
    diag $run->{stderr} if length $run->{stderr};
    my ( @hits, $lines );

    for my $record ( @{ all_records($root) } ) {
        push @hits, $record->[2] if $record->[0] eq 'hit';
        $lines = $record->[2] if $record->[0] eq 'lines';
    }
    return {
        output => $run->{stdout},
        hits   => join( q{,}, sort { $a <=> $b } @hits ),
        lines  => $lines,
        blind  => blind_records("$root/blind"),
    };
}

# The lines record of the shim names the lines with a statement, and its answer follows the interpreter.
# Before Perl 5.36 it names every statement and the line of each use.
# From Perl 5.36 on it leaves out the lines of each use and the statement of the file body on line 4.
# Perl 5.36 alone leaves out the constant of the file body on line 8 too.
my $statement_lines = $] < 5.036 ? '2,3,4,6,8,10' : $] < 5.038 ? '6,10'    : '6,8,10';
my $lines_since     = $] < 5.036 ? 'before 5.36'  : $] < 5.038 ? 'on 5.36' : 'from 5.38';
my $untraced        = line_trace(q{});
is $untraced->{output}, "12\n",           'the traced target runs';
is $untraced->{hits},   '2,3,4,6,8,10',   'the tracer records the lines of the target that ran';
is $untraced->{lines},  $statement_lines, "the lines that the shim names as statements $lines_since";

for my $template ( $PLANNED, $AMENDED ) {
    my $which = $template eq $PLANNED ? 'planned' : 'amended';

    for my $form (qw(module program)) {
        is observed( form => $form, template => $template, clear => 1 ), $FALLBACK,
          "E9: the $which statement in a $form without environment records in the fallback directory";
        is observed( form => $form, template => $template, clear => 1, switches => ['-T'] ), $FALLBACK,
          "E9: and the $which statement in a $form does so in taint mode";
    }

    # A process with the shim: the statement calls the shim and writes no record of its own.
    my $with_shim = target( form => 'module', template => $template );
    write_file( "$with_shim/gen/Test/Mutation/Shim/G$number.pm", shim_stub() );
    my $called = run_bare(
        root => $with_shim,
        env  => { $variable => "$with_shim/records", SEEN_LOG => "$with_shim/seen.log" },
        args => [ "-I$with_shim/gen", "-MTest::Mutation::Shim::G$number", '-Ilib', 'script.pl' ],
    );
    is summary( $with_shim, $called ) . ' seen=' . shown( slurp("$with_shim/seen.log") ),
      'exit=0 output=41 records= fallback= error= seen=seen\t17\n',
      "E9: the $which statement calls the shim of its generation where the process has one";

    # autodie replaces open in the package of the file, so package DB alone keeps it out of the statement.
    my %unwritable = ( form => 'module', pragmas => ['use autodie;'], records => 'absent' );
    my $silent     = 'exit=0 output=41 records= fallback= error=';
    is observed( %unwritable, template => $template ), $silent,
      "E9: the $which statement under autodie stays silent where it cannot write";
    ( my $bare_calls = $template ) =~ s/CORE:://g;
    is observed( %unwritable, template => $bare_calls ), $silent,
      "E9: the $which statement without CORE:: stays silent too, because package DB is outside the reach of autodie";
    ( my $unprotected = $bare_calls ) =~ s/package DB;//;
    like observed( %unwritable, template => $unprotected ),
      qr/\Aexit=255 output= records= fallback= error=Can't open /,
      "E9: the $which statement without package DB and without CORE:: stops a program under autodie";

    # CORE:: keeps out a replacement of open that reaches every package.
    my %replaced = ( form => 'module', switches => ['-MReplaced'] );
    is observed( %replaced, template => $template ), $RECORDED,
      "E9: the $which statement records where a module replaced open for every package";
    is observed( %replaced, template => $bare_calls ),
      'exit=255 output= records= fallback= error=a replacement of open ran',
      "E9: the $which statement without CORE:: runs the replacement, so the prefix is needed";

    # The statement adds no trace point: it compiles in package DB, where the interpreter traces nothing.
    my $prefix = statement( $template, '/tmp/fallback' );
    my $traced = line_trace($prefix);
    is $traced->{blind}, 'blind\t17\n', "the $which statement of the traced target records";
    is_deeply [ @{$traced}{qw(output hits lines)} ], [ @{$untraced}{qw(output hits lines)} ],
      "E9: the $which statement adds no hit and no statement line under the tracer";
    ( my $in_own_package = $prefix ) =~ s/package DB;//;
    is line_trace($in_own_package)->{hits}, '2,3,4,6,8,9,10',
      "E9: the $which statement without package DB adds a hit on its line, so the package is needed";

    # UNITCHECK runs when the file has compiled: before the first statement of a program, and under -c too.
    my $early     = project();
    my $statement = statement( $template, "$early/fallback" );
    write_file( "$early/script.pl",
        "my \@before = glob \"\$ENV{$variable}/blind-*.rec\";\n${statement}print scalar \@before, \" blind-\$\$.rec\\n\";\n"
    );
    my $ran = run_bare( root => $early, env => { $variable => "$early/records" }, args => ['script.pl'] );
    my ($named) = map { m{([^/]+)\z} } glob "$early/records/blind-*.rec";
    is $ran->{stdout}, "1 $named\n",
      "E9: the $which statement of a program records before the first statement runs, under the number of its process";

    for my $form (qw(module program)) {
        my $checked = target( form => $form, template => $template );
        my $run     = run_bare(
            root => $checked,
            env  => { $variable => "$checked/records" },
            args => [ '-c', '-Ilib', 'script.pl' ]
        );
        is summary( $checked, $run ), 'exit=0 output= records=blind\t17\n fallback= error=script.pl syntax OK',
          "E9: the $which statement in a $form records under -c, where nothing runs";
    }

    # Every compilation of the file records once, whichever way the text reaches the interpreter.
    my %loaded = (
        'a require'                 => [ "require Seen::Module;\n",                 'blind\t17\n' ],
        'do FILE twice'             => [ "do './lib/Seen/Module.pm' or die;\n" x 2, 'blind\t17\nblind\t17\n' ],
        'a string eval of the text' => [
            "open my \$in, '<', 'lib/Seen/Module.pm' or die;\nmy \$text = do { local \$/ = undef; <\$in> };\n"
              . "eval \$text or die \$\@;\n",
            'blind\t17\n'
        ],
    );
    for my $way ( sort keys %loaded ) {
        my ( $code, $records ) = @{ $loaded{$way} };
        my $root = target( form => 'module', template => $template );
        write_file( "$root/script.pl", $code . "print Seen::Module::value(), \"\\n\";\n" );
        my $run = run_bare( root => $root, env => { $variable => "$root/records" }, args => [ '-Ilib', 'script.pl' ] );
        is summary( $root, $run ), "exit=0 output=41 records=$records fallback= error=",
          "E9: the $which statement records after $way";
    }

    # A file with a compile error: a module records nothing, and a program records where the error follows the statement.
    my %broken = (
        'a module with an error after the statement' =>
          [ 'module', "package Seen::Module;\nsub value { return 41 }\n${statement}1 + ;\n", q{} ],
        'a module with an error before the statement' =>
          [ 'module', "package Seen::Module;\nsub value { return 41 + }\n${statement}1;\n", q{} ],
        'a program with an error after the statement' =>
          [ 'program', "sub value { return 41 }\n${statement}print value() + ;\n", 'blind\t17\n' ],
        'a program with an error before the statement' =>
          [ 'program', "sub value { return 41 + }\n${statement}print value(), \"\\n\";\n", q{} ],
    );
    for my $case ( sort keys %broken ) {
        my ( $form, $text, $records ) = @{ $broken{$case} };
        my $root = project();
        write_file( $form eq 'module' ? "$root/lib/Seen/Module.pm" : "$root/script.pl", $text );
        write_file( "$root/script.pl",
            "my \$ok = eval { require Seen::Module; 1 };\nprint \$ok ? 'loaded' : 'failed';\n" )
          if $form eq 'module';
        my $run = run_bare( root => $root, env => { $variable => "$root/records" }, args => [ '-Ilib', 'script.pl' ] );
        is "exit=$run->{status} output=$run->{stdout} records=" . blind_records("$root/records"),
          ( $form eq 'module' ? 'exit=0 output=failed' : 'exit=255 output=' ) . " records=$records",
          "E9: the $which statement in $case";
    }
}

done_testing;
