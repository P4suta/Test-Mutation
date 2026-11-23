use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file write_spec run_perl records all_records lib_dir);

sub module {
    my ( $package, $value ) = @_;
    return "package $package;\nsub value { return $value }\n1;\n";
}

sub shim_run {
    my ( $root, %run ) = @_;
    return run_perl(
        root => $root,
        env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records", %{ $run{env} || {} } },
        args => [ '-I' . lib_dir(), @{ $run{before} || [] }, '-MTest::Mutation::Shim', '-Ilib', 'script.pl' ],
    );
}

subtest 'an empty line in the spec does not end it' => sub {
    my $root = project();
    write_file( "$root/lib/One.pm", module( 'One', 1 ) );
    write_file( "$root/mutant.pm",  module( 'One', 2 ) );
    write_file( "$root/script.pl",  "use One;\nprint One::value();\n" );
    write_file( "$root/spec",       "trace\t0\n\ntarget\t$root/lib/One.pm\t$root/mutant.pm\n" );
    is shim_run($root)->{stdout}, '2', 'the target after the empty line is served';
};

subtest 'each of several targets keeps its own identity' => sub {
    my $root = project();
    write_file( "$root/lib/$_.pm", module( $_, 1 ) ) for qw(Aa Bb Cc);
    write_file( "$root/script.pl", "use Bb;\nprint Bb::value();\n" );
    write_spec(
        "$root/spec",
        trace   => 1,
        targets => [ map { [ "$root/lib/$_.pm", "$root/lib/$_.pm" ] } qw(Aa Bb Cc) ]
    );
    my $run = shim_run($root);
    is $run->{stdout}, '1', 'the program runs';
    my %by_kind;
    push @{ $by_kind{ $_->[0] } }, $_->[1] for @{ records($root) };
    is_deeply $by_kind{served},   ["$root/lib/Bb.pm"], 'the loaded target is served';
    is_deeply $by_kind{compiled}, ["$root/lib/Bb.pm"], 'the compiled record names the same target';
    is_deeply $by_kind{lines}, ["$root/lib/Bb.pm"], 'a target after one that was never loaded still reports its lines';
};

subtest 'a different file of the same name and size is left alone' => sub {
    my $root = project();
    write_file( "$root/lib/Same.pm",   module( 'Same', 1 ) );
    write_file( "$root/other/Same.pm", module( 'Same', 5 ) );
    write_file( "$root/mutant.pm",     module( 'Same', 2 ) );
    write_file( "$root/script.pl",     "use Same;\nprint Same::value();\n" );
    write_spec( "$root/spec", targets => [ [ "$root/lib/Same.pm", "$root/mutant.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', '-Iother', 'script.pl' ],
    );
    is $run->{stdout}, '5', 'the other file runs unmodified';
    is_deeply [ map { $_->[0] } @{ records($root) } ], ['end'], 'nothing is served and nothing bypasses the hook';
};

subtest 'two targets with one name and the same text keep their own replacements' => sub {
    my $root = project();
    write_file( "$root/lib/$_/Twin.pm",     "1;\n" ) for qw(One Two);
    write_file( "$root/second/Two/Twin.pm", "1;\n" );
    write_file( "$root/$_.pm",              "print '$_';\n1;\n" ) for qw(one two second);
    write_spec(
        "$root/spec",
        targets => [
            [ "$root/lib/One/Twin.pm",    "$root/one.pm" ],
            [ "$root/lib/Two/Twin.pm",    "$root/two.pm" ],
            [ "$root/second/Two/Twin.pm", "$root/second.pm" ],
        ]
    );
    write_file( "$root/script.pl", "require Two::Twin;\n" );
    is shim_run( $root, before => ['-Isecond'] )->{stdout}, 'second',
      'a target with the name and the text of an earlier target gets its own replacement';
    write_file( "$root/blib/lib/$_/Twin.pm", "1;\n" ) for qw(One Two);

    for my $name (qw(One Two)) {
        write_file( "$root/script.pl", "require $name\::Twin;\n" );
        is shim_run($root)->{stdout}, lc $name, "the file of $name gets the replacement of $name";
        is shim_run( $root, before => ['-Iblib/lib'] )->{stdout}, lc $name, "and so does its copy in blib";
    }
    write_file( "$root/blib/lib/Other/Twin.pm", "1;\n" );
    write_file( "$root/script.pl",              "require Other::Twin;\n" );
    is shim_run( $root, before => ['-Iblib/lib'] )->{stdout}, 'one',
      'a copy under a third name gets the replacement of the first target in the spec';
};

subtest 'a replacement that cannot be opened leaves the original and an error record' => sub {
    my $root = project();
    write_file( "$root/lib/One.pm", module( 'One', 1 ) );
    write_file( "$root/script.pl",  "use One;\nprint One::value();\n" );
    write_spec( "$root/spec", targets => [ [ "$root/lib/One.pm", "$root/missing.pm" ] ] );
    my $run = shim_run($root);
    is $run->{stdout}, '1', 'the original runs';
    my ($error) = grep { $_->[0] eq 'error' } @{ records($root) };
    is $error->[1], "$root/lib/One.pm", 'the error record names the target';
    like $error->[2], qr/\Acannot open \Q$root\E\/missing[.]pm: /, 'and the reason';
};

subtest 'another debugger keeps its hook and tracing stays off' => sub {
    my $root = project();
    write_file( "$root/lib/One.pm",         module( 'One', 1 ) );
    write_file( "$root/lib/OwnDebugger.pm", "package OwnDebugger;\nsub DB::DB { return }\n1;\n" );
    write_file( "$root/script.pl",          "use One;\nprint One::value();\n" );
    write_spec( "$root/spec", trace => 1, targets => [ [ "$root/lib/One.pm", "$root/lib/One.pm" ] ] );
    my $run = shim_run( $root, before => [ '-Ilib', '-MOwnDebugger' ] );
    is $run->{stdout}, '1', 'the program runs';
    my @all = @{ all_records($root) };
    is_deeply [ map { $_->[1] } grep { $_->[0] eq 'begin' } @all ], [0], 'the record marks the process as untraced';
    is scalar( grep { $_->[0] eq 'hit' || $_->[0] eq 'lines' } @all ), 0, 'no line is recorded';
};

subtest 'a debugger that takes over after an outer shim turns tracing off' => sub {
    my $root = project();
    open my $handle, '<', lib_dir() . '/Test/Mutation/Shim.pm' or die "read the shim: $!";
    my $outer = do { local $/ = undef; <$handle> };
    close $handle or die "close the shim: $!";

    # The copy takes a generation that no run around this test uses.
    my $number = 500 + ( $ENV{TEST_MUTATION_GENERATION} || 0 );
    $outer =~ s/^package Test::Mutation::Shim;/package Test::Mutation::Shim::G$number;/m or die 'no package line';
    $outer =~ s/^my \$GENERATION = 0;/my \$GENERATION = $number;/m                       or die 'no generation line';
    write_file( "$root/gen/Test/Mutation/Shim/G$number.pm", $outer );
    write_file( "$root/gen/Takeover.pm", "package Takeover;\nno warnings;\n*DB::DB = sub { return };\n1;\n" );
    write_file( "$root/lib/One.pm",      module( 'One', 1 ) );
    write_file( "$root/script.pl",       "use One;\nprint One::value();\n" );
    write_spec( "$root/spec", trace => 1, targets => [ [ "$root/lib/One.pm", "$root/lib/One.pm" ] ] );
    mkdir "$root/outer" or die "mkdir: $!";
    my $run = shim_run(
        $root,
        env    => { "TEST_MUTATION_SPEC_G$number" => "$root/spec", "TEST_MUTATION_RECORD_G$number" => "$root/outer" },
        before => [ "-I$root/gen", "-MTest::Mutation::Shim::G$number", '-MTakeover' ],
    );
    is $run->{stdout}, '1', 'the program runs' or diag $run->{stderr};
    my @all = @{ all_records($root) };
    is_deeply [ map { $_->[1] } grep { $_->[0] eq 'begin' } @all ], [0], 'the record marks the process as untraced';
    is scalar( grep { $_->[0] eq 'hit' } @all ), 0, 'no line is recorded';
};

subtest 'the records at the end follow the order of the spec' => sub {
    my $root = project();
    write_file( "$root/lib/$_.pm", module( $_, 1 ) ) for qw(Aa Bb Cc);
    write_file( "$root/script.pl", "use Cc;\nuse Aa;\nprint Aa::value();\n" );
    write_spec(
        "$root/spec",
        trace   => 1,
        targets => [ map { [ "$root/lib/$_.pm", "$root/lib/$_.pm" ] } qw(Aa Bb Cc) ]
    );
    my $run = shim_run($root);
    is $run->{stdout}, '1', 'the program runs';
    is_deeply [ map { $_->[1] } grep { $_->[0] eq 'lines' } @{ records($root) } ],
      [ "$root/lib/Aa.pm", "$root/lib/Cc.pm" ],
      'the first target of the spec reports first, whatever the load order';
};

subtest 'use lib keeps other hooks and directories in place' => sub {
    my $root = project();
    write_file( "$root/lib/One.pm", module( 'One', 1 ) );
    write_file( "$root/mutant.pm",  module( 'One', 2 ) );
    write_file( "$root/script.pl",  <<'PERL' );
my $other;
BEGIN { $other = sub { return }; push @INC, $other }
use lib 'extra';
use One;
print join ',', One::value(), scalar( grep { ref && $_ == $other } @INC ), scalar( grep { !ref && $_ eq 'extra' } @INC ),
  scalar( grep { ref } @INC ) - $ENV{OUTER_HOOKS};
PERL
    write_spec( "$root/spec", targets => [ [ "$root/lib/One.pm", "$root/mutant.pm" ] ] );
    is shim_run($root)->{stdout}, '2,1,1,2', 'the mutant, the other hook once, the directory, and two hooks in all';
};

subtest 'a tab in a path stays inside its field' => sub {
    my $root = project();
    write_file( "$root/lib/Odd\tName.pm", module( 'Odd', 1 ) );
    write_file( "$root/script.pl",        "require \"Odd\\tName.pm\";\nprint Odd::value();\n" );
    write_file( "$root/spec",             "trace\t0\n" );
    my $run = run_perl(
        root => $root,
        env  => { TEST_MUTATION_RECORD => "$root/records" },
        args => [
            '-I' . lib_dir(),
            '-MTest::Mutation::Shim',
            '-Ilib',
            '-e',
            "Test::Mutation::Shim::activate( { trace => 0, targets => [ { original => qq{$root/lib/Odd\\tName.pm}, serve => qq{$root/lib/Odd\\tName.pm} } ] }, \$ENV{TEST_MUTATION_RECORD} ); do './script.pl' or die \$@;",
        ],
    );
    is $run->{stdout}, '1', 'the program runs' or diag $run->{stderr};
    my ($served) = grep { $_->[0] eq 'served' } @{ records($root) };
    is_deeply $served, [ 'served', "$root/lib/Odd Name.pm" ], 'the tab becomes a space and the record has two fields';
};

subtest 'a failed load of another module raises no warning at the end' => sub {
    my $root = project();
    write_file( "$root/lib/One.pm",    module( 'One', 1 ) );
    write_file( "$root/lib/Broken.pm", "package Broken;\nsub x { 1 +* }\n1;\n" );
    write_file( "$root/script.pl",     "my \$ok = eval { require Broken; 1 };\nprint \$ok ? 'loaded' : 'failed';\n" );
    write_spec( "$root/spec", targets => [ [ "$root/lib/One.pm", "$root/lib/One.pm" ] ] );
    my $run = shim_run($root);
    is $run->{stdout}, 'failed', 'the program runs';
    unlike $run->{stderr}, qr/uninitialized|Shim/, 'no warning from the shim';
};

done_testing;
