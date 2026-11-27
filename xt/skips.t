use v5.36;
use Test2::V0;
use PPI;
use lib 't/lib';
use Gate;
use Library;

# A test that skips itself goes missing without notice.
# Every skip therefore goes through Capability, which fails where a job requires the capability.

my %SKIPS = map { $_ => 1 } qw(skip skip_all todo_skip);

sub direct_skips ($code) {
    my $document = PPI::Document->new( \$code ) or die "the test file does not parse\n";
    my @words    = grep { $SKIPS{ $_->content } } @{ $document->find('PPI::Token::Word') || [] };

    # A method named skip belongs to its object, and a key named skip belongs to its list.
    # `plan skip_all => $reason` is a skip all the same.
    my @calls = grep {
        my ( $before, $after ) = ( $_->sprevious_sibling, $_->snext_sibling );
        my $method = $before && $before->content eq '->';
        my $key    = $after  && $after->content eq '=>' && $_->content ne 'skip_all';
        !$method && !$key
    } @words;
    return [ map { sprintf 'line %d calls %s', $_->line_number, $_->content } @calls ];
}

subtest 'the gate rejects a test that skips on its own' => sub {
    is direct_skips("use Test2::V0;\nskip_all 'no git' if !\$git;\nok 1;\n"), ['line 2 calls skip_all'],
      'a file that skips itself';
    is direct_skips("SKIP: {\n    skip 'no git', 1 if !\$git;\n    ok 1;\n}\n"), ['line 2 calls skip'],
      'a skipped block';
    is direct_skips("use Test::More;\nplan skip_all => 'no git';\n"), ['line 2 calls skip_all'], 'a skipping plan';
    is direct_skips("Capability::need( 'git', \$git, 'no git' );\n# skip_all 'x'\nmy \$t = q{skip 'x'};\nok 1;\n"), [],
      'a capability, a comment, and a string';
    is direct_skips("\$context->skip( 'a case', 'no git' );\n"),        [], 'a method of another object';
    is direct_skips("snapshot( root => \$root, skip => ['.git'] );\n"), [], 'a key of a list';
};

my @files = map { Library::tests($_)->@* } 't', 'xt';
my @found;
for my $file ( grep { !m{\At/(?:fixtures|corpus)/} } @files ) {
    open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
    my $code = do { local $/ = undef; readline $handle };
    close $handle or die "close $file: $!";
    push @found, map { "$file: $_" } direct_skips($code)->@*;
}
is \@found, [], 'no test skips without naming a capability';
Gate::checked( 'test files', scalar @files, at_least => 80 );

done_testing;
