use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Capability;
use Fixture qw(ran write_file);
use Test::Mutation::Report::Json;
use Test::Mutation::Source;

my $root = File::Temp::tempdir( CLEANUP => 1 );
my $body = "sub sum { return \$_[0] + \$_[1] }\nsub total { return \$_[0] + \$_[1] }\n1;\n";
for my $name (qw(Alpha Beta)) {
    write_file( "$root/lib/$name.pm", "package $name;\n$body" );
}
write_file( "$root/t/pass.t", "use Test::More tests => 1;\nok 1;\n" );

sub run_scope (@options) {
    ran( 0, $root, 'run', '--jobs', 1, '--format', 'json', @options );
    return Test::Mutation::Report::Json::parse(
        Test::Mutation::Source::read_bytes("$root/mutation-report/mutation.json") );
}
my $ordinary = run_scope();
my @gaps     = map  { $_->{mutant} } grep { $_->{status} eq 'NoCoverage' } $ordinary->entries->@*;
my @alpha    = grep { $_->path eq 'lib/Alpha.pm' } @gaps;
my @third    = grep { $_->from->[0] == 3 } @alpha;
ok @third && @third < @alpha && @alpha < @gaps, 'the measured gaps span two lines and two files';

sub ids ($result) {
    return [ map { $_->{mutant}->id } $result->entries->@* ];
}
my $file = run_scope( '--undetected', 'lib/Alpha.pm' );
is ids($file), [ map { $_->id } @alpha ], 'a file rechecks only gaps measured in that file';
my $range = run_scope( '--undetected', 'lib/Alpha.pm:3' );
is ids($range), [ map { $_->id } @third ], 'a line range rechecks only its measured gaps';
is $range->selection->{paths}, { 'lib/Alpha.pm' => [ [ 3, 3 ] ] }, 'the report preserves the requested range';
subtest 'Git line selection intersects the historical scope' => sub {
    Capability::need( 'git', length qx{git --version 2>/dev/null}, 'the test needs the git command' );
    my @git = (
        'git',                             '-C', $root,            '-c',
        'core.hooksPath=/dev/null',        '-c', 'user.name=Test', '-c',
        'user.email=test@example.invalid', '-c', 'commit.gpgsign=false'
    );
    system( @git, 'init', '-q' ) == 0                    or die 'git init failed';
    system( @git, 'add', 'lib', 't' ) == 0               or die 'git add failed';
    system( @git, 'commit', '-q', '-m', 'fixture' ) == 0 or die 'git commit failed';
    my $changed = $body =~ s/(sub total [^\n]+)/$1 # changed/r;
    write_file( "$root/lib/Alpha.pm", "package Alpha;\n$changed" );
    is ids( run_scope( '--undetected', '--since', 'HEAD' ) ), [ map { $_->id } @third ],
      'only saved gaps on changed lines are remeasured';
    is ids( run_scope( '--undetected', '--since', 'HEAD', 'lib/Beta.pm' ) ), [],
      'disjoint Git and file scopes yield an empty measurement';
};
done_testing;
