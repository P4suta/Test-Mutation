package Discovery::Probe;
use v5.36;
use File::Path ();
use Discovery::Check;
use Discovery::Known;
use Discovery::Project;

# What a test process is given: its taint mode, its module search path, and its environment.
# Each test of the bench writes these once, under prove and under the unmodified run of the tool, and the two must agree.

my @FIRST_LINES = (
    [ 'plain',     undef ],
    [ 'T',         '#!perl -T' ],
    [ 'bundle-wT', '#!perl -wT' ],
    [ 'bundle-Tw', '#!perl -Tw' ],
    [ 'lower',     '#!perl -t' ],
    [ 'include',   '#!perl -It/lib' ],
    [ 'separate',  '#!perl -w -T' ],
    [ 'space',     '#! perl -T' ],
    [ 'tab',       "#!perl\t-T" ],
);

# The test writes its state the first time it runs, so the run of a mutant adds nothing to it.
my $TEST = <<'PERL';
use strict;
use warnings;
use Cwd ();
use Known;
if ( !-e '<<file>>' && open my $out, '>', '<<file>>' ) {
    print {$out} 'taint=', ${^TAINT}, "\n", 'cwd=', Cwd::getcwd(), "\n";
    print {$out} 'inc=', ( ref $_ ? 'CODE' : $_ ), "\n" for @INC;
    print {$out} "env=$_=$ENV{$_}\n" for sort keys %ENV;
    close $out;
}
print "1..1\nok 1 - probed\n";
PERL

sub first_lines () {
    return map { $_->[0] } @FIRST_LINES;
}

sub bench () {
    my $project = Discovery::Project->new;
    my $states  = $project->scratch . '/states';
    File::Path::make_path($states);
    Discovery::Known->new( seed => 1, cells => 1, idle => 0, tests => 1 )->write($project);
    $project->remove('t/a.t');
    for my $line (@FIRST_LINES) {
        my ( $name, $first ) = $line->@*;
        $project->write( "t/$name.t", ( defined $first ? "$first\n" : q{} ) . $TEST =~ s{<<file>>}{$states/$name}gr );
    }
    $project->write( 't/lib/Helper.pm', "package Helper;\n1;\n" );
    return { project => $project, states => $states };
}

# The states that the tests wrote, by test, with the root of the run replaced by one word.
# The hook, the directory of the shim, and the variables that the tool owns stay out.
sub _states ($bench) {
    my %state;
    for my $name ( first_lines() ) {
        open my $in, '<', "$bench->{states}/$name" or next;
        chomp( my @lines = readline $in );
        close $in or die "close: $!";
        unlink "$bench->{states}/$name";
        my ($root) = map { /\Acwd=(.*)\z/ ? $1 : () } @lines;
        s/\Q$root\E/<root>/g for @lines;
        my %env = map { /\Aenv=([^=]+)=(.*)\z/s ? ( $1 => $2 ) : () } @lines;
        delete @env{ grep { /\ATEST_MUTATION_/ || $_ eq 'TMPDIR' || $_ eq 'PWD' } keys %env };
        $env{PERL5OPT} = join q{ }, grep { !/\A-MTest::Mutation::Shim/ } split q{ }, $env{PERL5OPT}
          if defined $env{PERL5OPT};
        delete $env{PERL5OPT} if defined $env{PERL5OPT} && !length $env{PERL5OPT};
        $env{PERL5LIB} = join q{:}, grep { !m{/[.]mutation/run-[^/]+/shim\z} } split /:/, $env{PERL5LIB}
          if defined $env{PERL5LIB};
        $state{"t/$name.t"} = {
            taint => ( map { /\Ataint=(.*)\z/ ? $1 : () } @lines )[0],
            inc   =>
              [ grep { $_ ne 'CODE' && !m{/[.]mutation/run-[^/]+/shim\z} } map { /\Ainc=(.*)\z/ ? $1 : () } @lines ],
            env => \%env,
        };
    }
    return \%state;
}

# prove runs first and the tool second, each on the tests in the project itself: the tests write nothing into it.
# The answer of prove stays the same, so the bench keeps it for a second comparison.
# The tool runs each time: a run that the memo answers starts no test, and no test would write its state.
sub compared ( $engine, $bench ) {
    my $project = $bench->{project};
    my @tests   = map { "t/$_.t" } first_lines();

    # The harness may itself run under prove, whose variables would reach both sides and hide a difference.
    local %ENV = %ENV;
    delete @ENV{ grep { /\AHARNESS_|\APERL_TEST_HARNESS/ } keys %ENV };
    if ( !$bench->{prove} ) {
        my $proved = $project->proves(@tests);
        my $under  = _states($bench);
        $bench->{prove} = { map { $_ => { ( $under->{$_} || {} )->%*, verdict => $proved->{$_} || 'fail' } } @tests };
    }
    my $run    = $engine->with( memo => undef )->run($project);
    my $given  = _states($bench);
    my %failed = map { $_ => 1 } $run->{baseline_failures}->@*;
    my %tool   = map { $_ => { ( $given->{$_} || {} )->%*, verdict => $failed{$_} ? 'fail' : 'pass' } } @tests;
    $bench->{observed} = scalar grep { defined $bench->{prove}{$_}{taint} && defined $tool{$_}{taint} } @tests;
    return Discovery::Check::findings( ['baseline'], prove => $bench->{prove}, tool => \%tool );
}

1;
