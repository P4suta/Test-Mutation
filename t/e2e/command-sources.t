use v5.36;
use Test2::V0;
use JSON::PP ();
use lib 't/e2e/lib';
use Fixture qw(copy_of ran write_file);
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Source;

my $root = copy_of('script');
write_file( "$root/bin/shell-command",    "#!/bin/sh\nexit 3\n" );
write_file( "$root/script/sub/helper.pl", "sub twice { return \$_[0] * 2 }\n1;\n" );
write_file( "$root/script/comment",       "#!/bin/sh\n# perl helper\nexit 0\n" );

my $run  = ran( 0, $root, 'run', '--format', 'json', '--jobs', 1, '--no-equivalence' );
my $data = JSON::PP->new->utf8->decode( Test::Mutation::Source::read_bytes("$root/mutation-report/mutation.json") );
is [ sort keys $data->{files}->%* ], [ 'bin/total', 'script/sub/helper.pl' ], 'the default selects only Perl programs';
my $mutants  = $data->{files}{'bin/total'}{mutants};
my ($sum)    = grep { $_->{description} eq 'replaced + with -' } @$mutants;
my ($unused) = grep { $_->{description} eq 'replaced * with /' } @$mutants;
is $sum->{testMutation}{status},    'Killed',     'the subprocess tests the addition';
is $unused->{testMutation}{status}, 'NoCoverage', 'loading the command does not execute its unused subroutine';

my $list = ran( 0, $root, 'list', '--source', 'script/**/*.pl' );
like $list->{stdout},   qr{script/sub/helper[.]pl}, 'an explicit selection includes the requested program';
unlike $list->{stdout}, qr{bin/total},              'an explicit selection replaces the defaults';
subtest 'explicit command sources and test paths keep their declared roles' => sub {
    write_file( "$root/bin/explicit", "sub sum { return 4 + 2 }\n1;\n" );
    my $selected = ran( 0, $root, 'list', '--source', 'bin/explicit' );
    like $selected->{stdout}, qr{bin/explicit}, 'an explicitly selected Perl source needs no interpreter line';
    write_file( "$root/bin/custom.t", "use Test::More tests => 1;\nok 1;\n" );
    my $config = Test::Mutation::Settings::of_call( { root => $root, test => ['bin/custom.t'] } );
    is Test::Mutation::Select::resolve( config => $config )->tests, ['bin/custom.t'],
      'a selected test under bin is not filtered by source recognition';
};

subtest 'a nested source also runs through the installed command name' => sub {
    my $nested    = copy_of('script');
    my $original  = Test::Mutation::Source::read_bytes("$nested/bin/total");
    my $installed = $original =~ s{\A[^\n]+}{#!$^X}r;
    write_file( "$nested/script/commands/total.pl", $original );
    write_file( "$nested/blib/script/total.pl",     $installed );
    write_file( "$nested/blib/bin/total.pl",        "#!perl\nprint qq{another command\\n};\n" );
    my $test = Test::Mutation::Source::read_bytes("$nested/t/command.t") =~ s{bin/total}{blib/script/total.pl}gr;
    write_file( "$nested/t/command.t", $test );
    ran( 0, $nested, 'run', '--source', 'script/**/*.pl', '--format', 'json', '--jobs', 1, '--no-equivalence' );
    my $report =
      JSON::PP->new->utf8->decode( Test::Mutation::Source::read_bytes("$nested/mutation-report/mutation.json") );
    my $entries    = $report->{files}{'script/commands/total.pl'}{mutants};
    my ($add)      = grep { $_->{description} eq 'replaced + with -' } @$entries;
    my ($multiply) = grep { $_->{description} eq 'replaced * with /' } @$entries;
    is $add->{testMutation}{status},      'Killed',     'the generated command runs the selected source change';
    is $multiply->{testMutation}{status}, 'NoCoverage', 'the generated command records its actual lines';
    is Test::Mutation::Source::read_bytes("$nested/blib/script/total.pl"), $installed,
      'the installed interpreter line stays intact in the project';
};
done_testing;
