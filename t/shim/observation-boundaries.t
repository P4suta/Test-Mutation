use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness          qw(all_records lib_dir project run_perl write_file);
use Test::Mutation::Shim ();

subtest 'a spec preserves extraction, ordered aliases and empty fields' => sub {
    my $root = project();
    my $spec =
      write_file( "$root/spec", "\ncommand\tcmd\tone\nextract\tother\ncommand\tcmd\ttwo\ntarget\tcmd\tcopy\t\n" );
    is_deeply Test::Mutation::Shim::read_spec($spec),
      {
        trace    => 0,
        targets  => [ { original => 'cmd', serve => 'copy', outside => q{} } ],
        commands => { cmd   => [qw(one two)] },
        extract  => { other => 1 }
      },
      'blank lines add no settings and extraction belongs to its original';
    my $missing = "$root/missing";
    my $parsed  = eval { Test::Mutation::Shim::read_spec($missing) };
    my $error   = $@;
    ok !defined $parsed, 'a missing spec supplies no settings';
    like $error, qr/\Amutation: cannot read spec \Q$missing\E: \S/, 'a missing spec names the file';
};

subtest 'the first eligible source owns a main program reached through an alias' => sub {
    my $root = project();
    my @source =
      map { write_file( "$root/$_/tool", "print qq{unrelated\\n};\n" ) } qw(extracted unrelated library later);
    my $main = write_file( "$root/installed/tool", <<'PERL' );
use strict;
my $value = 1;
$value += 2;
print "value=$value ", scalar <DATA>;
__DATA__
program data
PERL
    my $text = join q{}, map { "target\t$_\t$_\n" } @source;
    $text .= "extract\t$source[0]\n";
    $text .= "command\t$source[0]\t$main\ncommand\t$source[2]\t$root/missing\n";
    $text .= "command\t$source[2]\t$main\ncommand\t$source[3]\t$main\n";
    for my $placed ( 0, 1 ) {
        my $directory = "$root/records/$placed";
        mkdir $directory or die "create record set: $!";
        write_file( "$root/spec", "trace\t1\nobserve\t1\nplaced\t$placed\n$text" );
        my $run = run_perl(
            root => $root,
            args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', $main ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => $directory }
        );
        is $run->{status}, 0,                        'the selected script completes' or diag $run->{stderr};
        is $run->{stdout}, "value=3 program data\n", 'the filter preserves the program and DATA';
        is $run->{stderr}, q{},                      'an unavailable alternate path does not warn';
        my ($file) = glob "$directory/*.rec";
        open my $records, '<', $file or die "read records: $!";
        my @hits = grep { /^hit\t/ } <$records>;
        close $records or die "close records: $!";
        my %owners = map { ( split /\t/ )[1] => 1 } @hits;
        is_deeply [ sort keys %owners ], $placed ? [ $source[2] ] : [],
          'only a placed command can supply main-program coverage and the first matching alias owns it';
        ok scalar( grep { /\t3\n\z/ } @hits ), 'the statement in the installed alias has a hit' if $placed;
    }
};

subtest 'an unquotable load path keeps its on-disk behavior in a placed run' => sub {
    for my $placed ( 0, 1 ) {
        my $root   = project();
        my $name   = 'quoted"dir';
        my $source = write_file( "$root/$name/Quoted.pm", "package Quoted; sub answer { 11 } 1;\n" );
        my $copy   = write_file( "$root/mutant",          "package Quoted; sub answer { 22 } 1;\n" );
        write_file( "$root/spec",    "trace\t0\nplaced\t$placed\ntarget\t$source\t$copy\n" );
        write_file( "$root/test.pl", "require Quoted; print Quoted::answer(), qq{\\n};\n" );
        my $run = run_perl(
            root => $root,
            args => [ '-I' . lib_dir(), "-I$name", '-MTest::Mutation::Shim', 'test.pl' ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
        );
        is $run->{status}, 0, 'an unquotable include path remains loadable' or diag $run->{stderr};
        is $run->{stdout}, $placed ? "11\n" : "22\n", 'only in-place interception serves alternate bytes';
    }
};

subtest 'the source filters switch debugger compilation at code, data, and end of input' => sub {
    my $root = project();
    write_file( "$root/lib/Target.pm", "package Target;\n1;\n" );
    write_file( "$root/bin/fake-main", "1;\n" );
    write_file( "$root/filters.pl",    <<'PERL' );
use strict;
use warnings;
use Filter::Util::Call ();
use Test::Mutation::Shim ();
my ($filter, $bytes, $count);
no warnings 'redefine';
local *Filter::Util::Call::filter_add = sub { ($filter) = @_ };
local *Filter::Util::Call::filter_read = sub { $_ = $bytes; return $count };
my $main = 'bin/fake-main';
local $0 = $main;
my $module = 'lib/Target.pm';
Test::Mutation::Shim::activate({trace => 1, placed => 1, observe => 1,
    targets => [{original => $main, serve => $main}, {original => $module, serve => $module}]}, 'records');
my $table = do { no strict 'refs'; *{"main::_<$main"}{ARRAY} };
print 'lines-ready=', defined $table ? 1 : 0, "\n";
print 'start=', $^P & 6, "\n";
die "missing main filter\n" unless $filter;
for my $case ([1, "print 1;\n"], [1, "__DATA__\n"], [1, "print 2;\n"], [1, "__END__\n"], [0, q{}]) {
    ($count, $bytes) = @$case;
    my $result = $filter->();
    print "main=$result:", $^P & 6, "\n";
}
unshift @INC, 'lib';
my (undef, $file, $hook) = Test::Mutation::Shim::_serve(undef, 'Target.pm');
die 'missing module filter' unless $hook;
for my $text ("print 1;\n", "__DATA__\n", "print 2;\n", "__END__\n", q{}) {
    local $_ = $text;
    my $result = $hook->();
    print 'module=', defined $result ? $result : 'none', ':', $^P & 6, "\n";
}
close $file or die $!;
PERL
    my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'filters.pl' ] );
    is $run->{status}, 0, 'the command and module both install working filters' or diag $run->{stderr};
    is $run->{stdout},
      join( "\n",
        'lines-ready=1', 'start=6',
        qw(main=1:6 main=1:0 main=1:6 main=1:0 main=0:0),
        qw(module=1:6 module=1:0 module=1:6 module=1:0 module=0:0), q{} ),
      'the compiler traces only source and receives the true read count for both filters';
};

subtest 'each pending source keeps tracing until its own witness runs' => sub {
    my $root = project();
    write_file( "$root/pending.pl", <<'PERL' );
use strict;
use warnings;
use Test::Mutation::Shim ();
Test::Mutation::Shim::trace_source(0, 'A.pm', 'physical-A', 'records', 0);
my (@start) = glob 'records/*.rec';
print 'started=', scalar @start, "\n";
Test::Mutation::Shim::trace_source(1, 'B.pm', 'physical-B', 'records', 0);
Test::Mutation::Shim::_trace_compile(0);
print 'both=', $^P & 6, "\n";
Test::Mutation::Shim::seen(1);
print 'one=', $^P & 6, "\n";
Test::Mutation::Shim::seen(0);
print 'done=', $^P & 6, "\n";
PERL
    my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'pending.pl' ] );
    is $run->{status}, 0, 'interleaved sources can finish in reverse order' or diag $run->{stderr};
    is $run->{stdout}, "started=1\nboth=6\none=6\ndone=0\n",
      'pending compilations own the debugger flags and the start record';
    my @targets = map { $_->[1] } grep { $_->[0] eq 'lines' } @{ all_records($root) };
    is_deeply \@targets, [qw(B.pm A.pm A.pm B.pm)], 'finishing the first witnessed source still visits every target';
};

subtest 'eval tracing sets both filename flags in the test interpreter' => sub {
    for my $eval ( 0, 1 ) {
        my $root = project();
        write_file( "$root/eval.pl", <<'PERL' );
use strict;
use warnings;
use Test::Mutation::Shim ();
Test::Mutation::Shim::activate({trace => 1, trace_eval => shift, observe => 1, targets => []}, 'records');
print $^P & 0xc00, "\n";
PERL
        my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'eval.pl', $eval ] );
        is $run->{stdout}, ( $eval ? 0xc00 : 0 ) . "\n", 'the eval flags follow the spec';
    }
};

subtest 'the command selector stops before looking up aliases for a missing main program' => sub {
    my $root = project();
    write_file( "$root/bin/tool",  "print 1;\n" );
    write_file( "$root/lookup.pl", <<'PERL' );
use strict;
use warnings;
our ($count, $armed);
BEGIN {
    *CORE::GLOBAL::stat = sub ($) {
        my $path = shift;
        $count++ if $armed;
        return CORE::stat($path);
    };
}
use Test::Mutation::Shim ();
Test::Mutation::Shim::activate({observe => 1, targets => [{original => 'bin/tool', serve => 'bin/tool'}]}, 'records');
for my $program ('irrelevant', 'gone/tool') {
    local $0 = $program;
    local $armed = 1;
    local $count = 0;
    Test::Mutation::Shim::_trace_main({commands => {'bin/tool' => ['another/tool']}});
    print "$program=$count\n";
}
PERL
    my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'lookup.pl' ] );
    is $run->{status}, 0,                             'absent commands remain uninstrumented' or diag $run->{stderr};
    is $run->{stdout}, "irrelevant=0\ngone/tool=1\n", 'an unrelated name needs no lookup and a missing main needs one';
    is $run->{stderr}, q{},                           'unavailable identities cause no warnings';
};

subtest 'witnesses distinguish served targets from unseen targets with and without a tracer' => sub {
    for my $blind ( 0, 1 ) {
        my $root   = project();
        my $module = write_file( "$root/lib/Module.pm", "package Module;\n1;\n" );
        write_file( "$root/spec",             "trace\t$blind\ntarget\t$module\t$module\n" );
        write_file( "$root/OtherDebugger.pm", "package DB; sub DB {} 1;\n" );
        write_file( "$root/witness.pl",       <<'PERL' );
use strict;
use warnings;
Test::Mutation::Shim::seen(0);
require Module;
Test::Mutation::Shim::seen(0);
PERL
        my @args = ( '-I' . lib_dir(), '-I.', '-Ilib' );
        push @args, '-MOtherDebugger' if $blind;
        my $run = ShimHarness::run_bare(
            root => $root,
            args => [ @args, '-MTest::Mutation::Shim', 'witness.pl' ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
        );
        is $run->{status}, 0, 'the registered module loads with either debugger setting' or diag $run->{stderr};
        my @states = map { [ $_->[0], defined $_->[2] ? $_->[2] : q{} ] }
          grep { defined $_->[1] && $_->[1] eq $module } @{ all_records($root) };
        my $observed = $blind ? 'blind' : 'seen';
        is_deeply \@states, [ [ 'blind', q{} ], [ 'seen', 'opened' ], [ $observed, q{} ], [ $observed, q{} ] ],
          'both compilation and the explicit witness report their own observations';
    }
};

subtest 'finishing a main program still examines the modules loaded after it' => sub {
    my $root = project();
    my $main = write_file( "$root/bin/app", <<'PERL' );
use strict;
use warnings;
require Later;
Test::Mutation::Shim::seen(0);
my $dispatch = $Test::Mutation::Shim::TRACERS[-1];
$dispatch->('untracked/file.pl', 99);
PERL
    my $later = write_file( "$root/lib/Later.pm", "package Later;\n1;\n" );
    write_file( "$root/spec", "trace\t1\nplaced\t1\nobserve\t1\ntarget\t$main\t$main\ntarget\t$later\t$later\n" );
    my $run = ShimHarness::run_bare(
        root => $root,
        args => [ '-I' . lib_dir(), '-Ilib', '-MTest::Mutation::Shim', $main ],
        env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
    );
    is $run->{status}, 0, 'main program and ordinary module finish' or diag $run->{stderr};
    unlike $run->{stderr}, qr/uninitialized/, 'a debugger callback for an untracked file does not warn';
    my $records = all_records($root);
    is scalar( grep { $_->[0] eq 'seen' && $_->[1] eq $main } @$records ), 1,
      'a witnessed main program reports its compilation';
    is scalar( grep { $_->[0] eq 'blind' && $_->[1] eq $later } @$records ), 1,
      'the ordinary require has only on-disk evidence';
    is scalar( grep { $_->[0] eq 'hit' && $_->[1] ne $main } @$records ), 0, 'only the selected main has hit records';
};

done_testing;
