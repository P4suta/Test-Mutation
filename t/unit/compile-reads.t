use v5.36;
use Test2::V0;
use Test::Mutation::Syntax::PPI;

sub reads ($source) {
    return scalar Test::Mutation::Syntax::PPI::compile_reads($source);
}

subtest 'scheduled blocks identify the file operands of read-only open' => sub {
    is reads(q{BEGIN { open my $in, '<', $ENV{TABLE} or die $!; close $in }}), [ [ env => 'TABLE' ] ],
      'the target environment supplies one named input';
    is reads(q{UNITCHECK { CORE::open(my $in, '<:raw', '/data/file') }}), [ [ file => '/data/file' ] ],
      'a literal path and a PerlIO layer identify one input';
    is reads(q{sub load { open my $in, '<', make_path() } # BEGIN }), [],
      'runtime statements do not run in the compiler';
};

subtest 'the compiler cannot identify an indirect read from its operands' => sub {
    is reads(q{BEGIN { open my $in, '<', $ENV{TABLE} . '.other' }}), undef,
      'a path expression is not a single variable';
    is reads(q{BEGIN { read_table() }}), undef, 'a helper may run arbitrary code';
    is reads(q{BEGIN { $ENV{TABLE} = '/other'; open my $in, '<', $ENV{TABLE} }}), undef,
      'the launch environment does not determine a reassigned variable';
};

done_testing;
