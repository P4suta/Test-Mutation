use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Gate;
use Invariants;
use Library;
use Samples;
use Sources;
use Space;
use World;
use Test::Mutation ();
use Test::Mutation::CLI;
use Test::Mutation::Config;
use Test::Mutation::Merge;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Report::Json;
use Test::Mutation::Runner;

# S8, the messages: every message that the code raises, and the cases of this file that make the code say it.
# No catalog names the messages yet, so the space reads them from the die statements and from the subroutines that report.

my @reporters = qw(_warn _usage _refused);
my @files     = ( 'bin/mutation', Library::modules()->@* );
my %inventory;
for my $file (@files) {
    my %message = map { $_ => 1 } Sources::messages( Sources::slurp($file), @reporters )->@*;
    $inventory{$file} = [ sort keys %message ] if %message;
}

my $tree = Space::tree();
my %text;

# What a piece of code says when it dies, and what a command line prints.
sub raised ( $file, $code ) {
    my $lived = eval { $code->(); 1 };
    push $text{$file}->@*, $lived ? () : "$@";
    return;
}

sub printed ( $file, $argv, %fact ) {
    my $observation = World::observe( $argv, cwd => $tree, %fact );
    push $text{$file}->@*, $observation->{stderr}, $observation->{stdout};
    return $observation;
}

sub part ( $shard, %arg ) {
    return {
        name   => "part-$shard",
        result => Samples::result(
            statuses  => ['Killed'],
            shard     => $shard,
            inventory => { mutants => 2, digest => 'a' x 64 },
            %arg
        )
    };
}

sub merged (@parts) {
    return raised( 'lib/Test/Mutation/Merge.pm', sub { Test::Mutation::Merge::merge( \@parts ) } );
}

subtest 'the space rejects a message that no case produces' => sub {
    my $code = "sub read_file (\$path) { open my \$in, '<', \$path or die \"cannot read \$path: \$!\\n\"; return }\n"
      . "sub check (\$n) { die \"the count \$n is too large\\n\" if \$n > 9; return }\n";
    my $messages = Sources::messages($code);
    is [ Invariants::message( $messages, ["mutation: cannot read a.toml: No such file or directory\n"] ) ],
      ["the count \x{2026} is too large"], 'the message without a case';
    is [ Invariants::message( $messages, [ "cannot read a: gone\n", "the count 12 is too large\n" ] ) ], [],
      'a case for each message';
};

# The library and the configuration.
raised( 'lib/Test/Mutation.pm', sub { Test::Mutation::mutants( root => $tree, nonesuch => 1 ) } );
my %layers = ( root => $tree, defaults => {}, cli => {} );
for my $file ( { nonesuch => 1 }, { nonesuch => {} }, { test => { nonesuch => 1 } } ) {
    raised( 'lib/Test/Mutation/Config.pm', sub { Test::Mutation::Config->from_layers( %layers, file => $file ) } );
}
raised( 'lib/Test/Mutation/Config.pm', sub { Test::Mutation::Config::read_file("$tree/absent.toml") } );
raised( 'lib/Test/Mutation/Mutator/Catalog.pm',
    sub { Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => ['nonesuch'], disable => [] ) } );

# The command line: a refusal of the plan, a refusal while the command runs, and an error of a run.
printed( 'lib/Test/Mutation/CLI.pm', $_ )
  for [ '--root', 'absent', 'list' ], [ 'show', 'zzzz' ], [ 'merge', 'absent.json' ];
{
    my $plan = World::observe( [ '--root', $tree, 'list' ], cwd => $tree, run => 'cheap' )->{plan};
    open my $errors, '>', \my $said or die "open: $!";
    Test::Mutation::CLI::execute( { $plan->%*, directory => 'gone' },
        { World::facts( cwd => $tree ), out => $errors, err => $errors } );
    push $text{'lib/Test/Mutation/CLI.pm'}->@*, $said;
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub { return Samples::result( statuses => ['Survived'] ) };
    printed(
        'lib/Test/Mutation/CLI.pm',
        [ 'run', '--format', 'github' ],
        env => { GITHUB_STEP_SUMMARY => "$tree/absent/summary.md" }
    );
}

# The merge of the parts of a run, and the report file that it reads.
merged();
merged( { name => 'whole', result => Samples::result( statuses => ['Killed'] ) } );
merged( part( '1/2', inventory         => undef ) );
merged( part( '1/2', baseline_failures => [ { test => 't/a.t', output => q{}, errors => q{} } ] ) );
merged( part('1/2'), part('1/3') );
merged( part('1/2'), part( '2/2', inventory => { mutants => 2, digest => 'b' x 64 } ) );
merged( part('1/2'), part('1/2') );
merged( part('1/2') );
merged( part('1/3') );
merged( part('1/2'), part('2/2') );
merged(
    part( '1/2', inventory => { mutants => 4, digest => 'a' x 64 } ),
    part( '2/2', statuses  => [], inventory => { mutants => 4, digest => 'a' x 64 } )
);

my $report = Test::Mutation::Report::Json::render( Samples::result( statuses => ['Killed'] ), high => 80, low => 60 );
for my $broken (
    'no document',
    '{}',
    '{"testMutation":{}}',
    $report =~ s/"line" : 1/"line" : 99/r,
    $report =~ s/("end" : \{\s+"column" : )\d+/${1}1/r,
    $report =~ s/"mutatorName" : "arithmetic"/"mutatorName" : "arithmetic", "id" : 7/r =~
    s/"id" : "[0-9a-f]+"/"id" : "short"/r
  )
{
    raised( 'lib/Test/Mutation/Report/Json.pm', sub { Test::Mutation::Report::Json::parse($broken) } );
}

# A run without a test: the runner warns, and the report prints the warning.
printed( 'lib/Test/Mutation/Runner.pm', [ 'run', '--format', 'terminal', '--jobs', 1, '--test', 't/nothing*.t' ] );

my ( @unheard, $messages, $heard );
for my $file ( sort keys %inventory ) {
    my @unsaid = Invariants::message( $inventory{$file}, $text{$file} || [] );
    $messages += $inventory{$file}->@*;
    $heard    += $inventory{$file}->@* - @unsaid;
    note "$file: no case produces: $_" for @unsaid;
    push @unheard, sprintf '%s: %d of %d messages that no case produces', $file, scalar @unsaid,
      scalar $inventory{$file}->@*
      if @unsaid;
}
Gate::findings( 'contract-message-messages', \@unheard );
Gate::checked( 'messages of the library',       $messages, at_least => 75 );
Gate::checked( 'messages that a case produces', $heard,    at_least => 25 );

done_testing;
