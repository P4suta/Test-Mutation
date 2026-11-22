use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file write_spec run_perl records lib_dir);

my $source = <<'PERL';
package Foo::Data;
use strict;
use warnings;

sub lines {
    my @lines = <DATA>;
    chomp @lines;
    return @lines;
}

sub reread {
    seek DATA, 0, 0;
    my @all = <DATA>;
    return scalar @all;
}

1;

__DATA__
alpha
beta
PERL

my $script = <<'PERL';
use Foo::Data;
print join( ',', Foo::Data::lines() ), "\n";
print Foo::Data::reread(), "\n";
PERL

my $lines_in_file = () = $source =~ /\n/g;

for my $trace ( 0, 1 ) {
    subtest "the DATA handle works when trace is $trace" => sub {
        my $root = project();
        write_file( "$root/lib/Foo/Data.pm", $source );
        write_file( "$root/script.pl",       $script );
        write_spec(
            "$root/spec",
            trace   => $trace,
            targets => [ [ "$root/lib/Foo/Data.pm", "$root/lib/Foo/Data.pm" ] ]
        );
        my $run = run_perl(
            root => $root,
            env  => { PERMUTL_SPEC => "$root/spec", PERMUTL_RECORD => "$root/records" },
            args => [ '-I' . lib_dir(), '-MPermutl::Shim', '-Ilib', 'script.pl' ],
        );
        is $run->{status}, 0,                              'exit status' or diag $run->{stderr};
        is $run->{stderr}, q{},                            'no warnings';
        is $run->{stdout}, "alpha,beta\n$lines_in_file\n", 'DATA reads the data section and rereads the whole file';
    };
}

done_testing;
