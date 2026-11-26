use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(copy_of ran write_file);
use Test::Mutation::Environment;
use Test::Mutation::Source;

my $pod = Test::Mutation::Source::read_bytes('bin/mutation');
my ($section) = $pod =~ /^=head1 ENVIRONMENT\n(.*?)(?=^=head1|\z)/ms;
ok defined $section, 'the installed command documents the environment';
my @documented;
while ( $section =~ /^=item C<([^>]+)>\n\n([^\n]+)$/mg ) {
    push @documented, { name => $1, meaning => $2 };
}
my $rows = Test::Mutation::Environment::rows();
is $rows, \@documented, 'each installed variable has the name and description returned by the public table';
my %names = map { $_->{name} => 1 } @$rows;
is scalar( keys %names ), scalar(@$rows), 'each variable is documented once';
ok $names{TEST_MUTATION_SPEC_Gn} && $names{TEST_MUTATION_RECORD_Gn},
  'nested measurements document both generation-specific inputs';
my $meaning = $rows->[0]{meaning};
$rows->[0]{meaning} = 'Changed by the caller';
is Test::Mutation::Environment::rows()->[0]{meaning}, $meaning, 'a caller cannot alter future copies of the catalog';

subtest 'a nested measurement loads the next generation of the shim' => sub {
    my $root = copy_of('calc');
    write_file( "$root/t/generation.t", <<'PERL' );
use Test::More tests => 3;
use Calc;
is $ENV{TEST_MUTATION_GENERATION}, 10, 'the nested test receives generation ten';
ok exists $INC{'Test/Mutation/Shim/G10.pm'}, 'the interpreter loaded the matching shim';
is Calc::add(4, 2), 6, 'the measured addition runs';
PERL
    local $ENV{TEST_MUTATION_GENERATION} = 9;
    my $measurement =
      ran( 0, $root, 'lib/Calc.pm:7', '--no-cache', '--jobs', 1, '--test', 't/generation.t', '--format', 'terminal' );
    like $measurement->{stderr}, qr/^The unmodified run passed: 1 test, 1 job$/m,
      'the nested command observes the unmodified project with its own shim';
};

subtest 'a reproduction command inherits its Perl switches and library path in its own copy' => sub {
    my $root = copy_of('calc');
    my $list = ran( 0, $root, 'list', 'lib/Calc.pm:7' );
    my ($id) = $list->{stdout} =~ /^([0-9a-f]{12})\s+[^\n]+replaced \+ with -$/m;
    ok $id, 'the fixture contains the subtraction replacement';
    my $library = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$library/InheritedOption.pm",  "package InheritedOption; sub marker { 'switch' } 1;\n" );
    write_file( "$library/InheritedLibrary.pm", "package InheritedLibrary; sub marker { 'library' } 1;\n" );
    local $ENV{PERL5OPT} = join q{ }, grep { defined && length } $ENV{PERL5OPT}, '-MInheritedOption';
    local $ENV{PERL5LIB} = join q{:}, grep { defined && length } $library, $ENV{PERL5LIB};
    my $observed = ran( 0, $root, 'exec', $id, '--in-place', '--', $^X, '-Ilib', '-MCalc', '-MInheritedLibrary', '-e',
        'mkdir q{exec-marker} or die $!; print join q{|}, InheritedOption::marker(), InheritedLibrary::marker(), Calc::add(5, 2)'
    );
    is $observed->{stdout}, 'switch|library|3', 'the child sees both inherited inputs and the selected mutant';
    ok !-e "$root/exec-marker", 'a command started with in-place measurement settings writes inside its copy';
};

done_testing;
