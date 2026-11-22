use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file write_spec run_perl all_records lib_dir);

my $target = <<'PERL';
package Foo::Traced;
use strict;
use warnings;
use Foo::Helper;
use constant LIMIT => 10 + 5;

my $loaded = 1;

sub classify {
    my ($n) = @_;
    if ( $n < 0 ) {
        return 'negative';
    }
    elsif ( $n == 0 ) {
        return 'zero';
    }
    return 'big' if $n > LIMIT;
    my $label =
      $n % 2
      ? 'odd'
      : 'even';
    return $label;
}

sub unused {
    return Foo::Helper::twice(21);
}

1;
PERL

my $helper = <<'PERL';
package Foo::Helper;
use strict;
use warnings;

sub twice {
    my ($n) = @_;
    return $n * 2;
}

1;
PERL

sub trace_run {
    my ($script) = @_;
    my $root = project();
    write_file( "$root/lib/Foo/Traced.pm", $target );
    write_file( "$root/lib/Foo/Helper.pm", $helper );
    write_file( "$root/script.pl",         $script );
    write_spec( "$root/spec", trace => 1, targets => [ [ "$root/lib/Foo/Traced.pm", "$root/lib/Foo/Traced.pm" ] ] );
    my $run = run_perl(
        root => $root,
        env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
        args => [ '-I' . lib_dir(), '-MPermutl::Shim', '-Ilib', 'script.pl' ],
    );
    my %lines = ( hits => [], lines => [] );

    for my $record ( @{ all_records($root) } ) {
        push @{ $lines{hits} }, $record->[2] if $record->[0] eq 'hit';
        $lines{lines} = [ split /,/, $record->[2] ] if $record->[0] eq 'lines';
        $lines{begin} = $record->[1]                if $record->[0] eq 'begin';
    }
    $lines{hits} = [ sort { $a <=> $b } @{ $lines{hits} } ];
    return ( $run, \%lines );
}

subtest 'executed statements are recorded by line' => sub {
    my ( $run, $lines ) =
      trace_run("use Foo::Traced;\nprint Foo::Traced::classify(3), Foo::Traced::classify(-1), \"\\n\";\n");
    is $run->{status},  0,               'exit status' or diag $run->{stderr};
    is $run->{stdout},  "oddnegative\n", 'the program output is unchanged';
    is $lines->{begin}, 1,               'the record marks the process as traced';
    is_deeply $lines->{hits}, [ 2, 3, 4, 5, 7, 10, 11, 12, 17, 18, 22, 29 ], 'hit lines'
      or diag "hits: @{ $lines->{hits} || [] }";
};

subtest 'an elsif condition is attributed to the line of its if' => sub {
    my ( $run, $lines ) = trace_run("use Foo::Traced;\nprint Foo::Traced::classify(0), \"\\n\";\n");
    is $run->{stdout}, "zero\n", 'the elsif branch ran';
    my %hit = map { $_ => 1 } @{ $lines->{hits} };
    ok $hit{11} && $hit{15} && !$hit{14}, 'the if line and the branch body are hit, the elsif line is absent'
      or diag "hits: @{ $lines->{hits} }";
};

subtest 'breakable lines include statements that never ran' => sub {
    my ( $run, $lines ) = trace_run("use Foo::Traced;\nprint Foo::Traced::classify(3), \"\\n\";\n");
    my %breakable = map { $_ => 1 } @{ $lines->{lines} };
    ok $breakable{26}, 'the body of the unused sub is breakable';
    ok $breakable{12}, 'the untaken branch is breakable';
    ok !$breakable{5}, 'the compile-time constant has no runtime statement'
      or diag "breakable: @{ $lines->{lines} }";
    ok !$breakable{2}, 'a use statement has no runtime statement';
};

subtest 'code outside the target is compiled without tracing' => sub {
    my ( $run, $lines ) = trace_run(<<'PERL');
use Foo::Traced;
Foo::Traced::unused();
no strict 'refs';
print 'helper=', scalar( @{'main::_<lib/Foo/Helper.pm'} ), ' script=', scalar( @{'main::_<script.pl'} ), "\n";
PERL
    is $run->{stdout}, "helper=0 script=0\n", 'no source lines are saved for other files';
};

done_testing;
