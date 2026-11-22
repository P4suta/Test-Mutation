use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture statuses write_file);
use Permutl::Report::Terminal;

my $root     = copy_of('calc');
my ($first)  = run_fixture( $root, cache => 1 );
my $measured = grep { $_->{status} =~ /\A(?:Killed|Survived)\z/ } $first->entries->@*;
my $boundary = 'lib/Calc.pm:12 replaced > with >=';

sub append ( $path, $text ) {
    open my $handle, '>>', "$root/$path" or die "append $path: $!";
    print {$handle} $text or die "append $path: $!";
    close $handle         or die "close $path: $!";
    return;
}

subtest 'a second run reuses every measured result' => sub {
    is $first->reused, 0, 'the first run measures every mutant';
    ok -f "$root/.permutl/cache.json", 'and writes the cache file';
    is statuses($first)->{$boundary}, 'Survived', 'the boundary mutant survives';

    my ($second) = run_fixture( $root, cache => 1 );
    is statuses($second), statuses($first), 'the statuses are unchanged';
    is $second->reused,   $measured,        'every measured result comes from the cache';
    is [ map { $_->{by} } $second->entries->@* ], [ map { $_->{by} } $first->entries->@* ],
      'the detecting tests are unchanged';
    like Permutl::Report::Terminal::render( $second, color => 0 ), qr/, $measured results from the cache$/m,
      'the summary states the number of reused results';
    unlike Permutl::Report::Terminal::render( $first, color => 0 ), qr/from the cache/, 'and stays silent without them';
};

subtest 'a run without the setting measures again' => sub {
    my ($plain) = run_fixture($root);
    is $plain->reused, 0, 'no result comes from the cache';
};

subtest 'a changed test invalidates the mutants it reaches' => sub {
    append( 't/add.t', "# a comment\n" );
    my ($third) = run_fixture( $root, cache => 1 );
    is statuses($third), statuses($first), 'the statuses are unchanged';
    ok $third->reused > 0,         'the mutants of the other test come from the cache';
    ok $third->reused < $measured, 'the mutants of the changed test run again';
};

subtest 'a new test that reaches a survivor replaces its cached result' => sub {
    write_file( "$root/t/zero.t", "use Test::More tests => 1;\nuse Calc;\nok !Calc::is_positive(0), 'zero';\n" );
    my ($fourth) = run_fixture( $root, cache => 1 );
    is statuses($fourth)->{$boundary}, 'Killed', 'the survivor is detected';
};

subtest 'a changed helper under the test directory invalidates every result' => sub {
    run_fixture( $root, cache => 1 );
    write_file( "$root/t/lib/Helper.pm", "package Helper;\n1;\n" );
    my ($fifth) = run_fixture( $root, cache => 1 );
    is $fifth->reused, 0, 'no result comes from the cache';
};

subtest 'a changed source invalidates the results of its tests' => sub {
    run_fixture( $root, cache => 1 );
    append( 'lib/Calc.pm', "# a comment\n" );
    my ($sixth) = run_fixture( $root, cache => 1 );
    is $sixth->reused, 0, 'no result comes from the cache';
};

subtest 'ignored survivors keep their statuses and reasons in a reused run' => sub {
    my $project  = copy_of('equivalent');
    my ($before) = run_fixture( $project, cache => 1 );
    my ($after)  = run_fixture( $project, cache => 1 );
    is statuses($after), statuses($before), 'the statuses are unchanged';
    is [ map { $_->{reason} } $after->entries->@* ], [ map { $_->{reason} } $before->entries->@* ],
      'the reasons are unchanged';
    is scalar( grep { $_->{status} eq 'Ignored' } $after->entries->@* ), 2, 'both ignored mutants stay ignored';
    is $after->reused,                                                   8, 'every result comes from the cache';
};

done_testing;
