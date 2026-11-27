use v5.36;
use Test2::V0;
use Cwd        ();
use File::Path ();
use File::Temp ();

# A system that refuses a step is rare, so each override fails one builtin while a case asks for it.
our %failing;    ## no critic (Variables::ProhibitPackageVars)

BEGIN {
    no warnings 'once';
    ## no critic (Variables::RequireLocalizedPunctuationVars)
    *CORE::GLOBAL::close = sub : prototype(;*) (@handle) {
        my $closed = @handle ? CORE::close( $handle[0] ) : CORE::close();
        return $closed if !$failing{close};
        $! = 5;
        return !1;
    };
    *CORE::GLOBAL::fork = sub {
        return CORE::fork() if !$failing{fork};
        $! = 35;
        return;
    };
    *CORE::GLOBAL::pipe = sub : prototype(**) {
        return CORE::pipe( $_[0], $_[1] ) if !$failing{pipe};
        $! = 24;
        return !1;
    };
    *CORE::GLOBAL::chmod = sub (@arguments) {
        return CORE::chmod(@arguments) if !$failing{chmod};
        $! = 1;
        return 0;
    };
    *CORE::GLOBAL::rmdir = sub : prototype(_) ($path) {
        return CORE::rmdir($path) if !$failing{rmdir};
        $! = 13;
        return !1;
    };
    ## use critic
}

use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Gate;
use Invariants;
use Library;
use Samples;
use Sources;
use Space;
use World;
use Test::Mutation ();
use Test::Mutation::Store;
use Test::Mutation::CLI;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Git;
use Test::Mutation::Merge;
use Test::Mutation::Message;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Pool;
use Test::Mutation::Record;
use Test::Mutation::Report::Json;
use Test::Mutation::Runner;
use Test::Mutation::Suppression;
use Test::Mutation::Tree;
use Test::Mutation::Verdict;

# S8, the messages: every message of the catalog, and the cases of this file that make the code say it.
# The catalog gives each message its text in one function, so the space counts the identifiers that pass there.
# A message that another process says reaches this one as text, and the case names the message that the text holds.

my $VALUE   = "\x{2026}";
my @catalog = map { $_->id } Test::Mutation::Message::rows()->@*;
my %said;
{
    # The type library compiles the check of a subroutine on its first call and puts the result in its place.
    # A call before the count keeps that step from replacing the counter.
    Test::Mutation::Message::text_of('inconclusive');
    no warnings 'redefine';
    my $text_of = \&Test::Mutation::Message::text_of;
    *Test::Mutation::Message::text_of = sub ( $id, @values ) {
        $said{$id} = 1;
        return $text_of->( $id, @values );
    };
}

my $tree    = Space::tree();
my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

# What a piece of code says when it dies, and what a command line prints.
sub raised ($code) {
    my $lived = eval { $code->(); 1 };
    return $lived ? q{} : "$@";
}

sub printed ( $argv, %fact ) {
    my $observation = World::observe( $argv, cwd => $tree, %fact );
    return $observation->{stderr} . $observation->{stdout};
}

sub template ($id) {
    return Test::Mutation::Message::row($id)->text =~ s/[{]\w+[}]/$VALUE/gr;
}

# A message that another process said reaches this one as text alone, so the case names the message that the text holds.
sub heard ( $id, $text ) {
    $said{$id} = 1 if !Invariants::message( [ template($id) ], [$text] );
    return;
}

sub unsaid ( $ids, $said ) {
    return grep { !$said->{$_} } $ids->@*;
}

# A run of a project in this process, so the catalog counts the warnings that the run gives.
sub measured ( $files, %settings ) {
    my $config = Test::Mutation::Settings::of_call( { root => directory( $files->%* ), jobs => 1, %settings } );
    return Test::Mutation::Runner::run( $config, sub (@) { return } );
}

sub part ( $shard, %arg ) {
    return {
        name   => "part-$shard",
        result => Samples::result(
            statuses           => ['Killed'],
            shard              => $shard,
            measurement_digest => 'c' x 64,
            dependency_digest  => 'd' x 64,
            inventory          => { mutants => 2, digest => 'a' x 64 },
            %arg
        )
    };
}

sub merged (@parts) {
    return raised( sub { Test::Mutation::Merge::merge( \@parts ) } );
}

sub directory (%files) {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1, DIR => $scratch ) );
    for my $path ( sort keys %files ) {
        my ($parent) = "$root/$path" =~ m{\A(.*)/};
        File::Path::make_path($parent);
        open my $handle, '>', "$root/$path" or die "write $path: $!";
        print {$handle} $files{$path} or die "write $path: $!";
        CORE::close($handle)          or die "close $path: $!";
    }
    return $root;
}

sub copied ( $from, $to, @link ) {
    return raised( sub { Test::Mutation::Tree::copy( from => $from, to => $to, skip => [], link => \@link ) } );
}

# One test in the pool, with the parts of its task that a case changes.
# The text is what the pool raised and what the test printed on its standard error.
sub pooled (%task) {
    my @queue = (
        {
            command         => [ $^X, '-e', '1' ],
            env             => {},
            cwd             => $scratch,
            timeout         => 20,
            output_limit    => 1_000_000,
            stop_on_failure => 0,
            %task
        }
    );
    my $errors = q{};
    my $raised = raised(
        sub {
            Test::Mutation::Pool::run(
                jobs => 1,
                next => sub { shift @queue },
                done => sub ( $task, $result ) { $errors = $result->{errors}; return }
            );
        }
    );
    return $raised . $errors;
}

# A test that fails before it has its own streams writes to standard error of the driver, which is the one of this file.
sub on_standard_error ($code) {
    open my $saved, '>&', \*STDERR              or die "save: $!";
    open STDERR,    '>',  "$scratch/driver.err" or die "redirect: $!";
    $code->();
    open STDERR, '>&', $saved or die "restore: $!";
    return Sources::slurp("$scratch/driver.err");
}

# A process of its own that loads the shim with a specification, and what it writes.
sub shim_says ( $spec, $before ) {
    local $ENV{TEST_MUTATION_SPEC} = $spec;
    my $code = "$before open STDERR, '>&', \\*STDOUT; require Test::Mutation::Shim; Test::Mutation::Shim->import;";
    open my $output, q{-|}, $^X, '-Ilib', '-e', $code or die "start: $!";
    my $text = do { local $/ = undef; readline $output };
    CORE::close($output);
    return defined $text ? $text : q{};
}

subtest 'invalid generated code identifies the mutant and its source' => sub {
    my $root = directory( Samples::incomplete_import()->%* );
    my $run =
      World::observe( [qw(run --source lib/Small.pm --enable call-swap --jobs 1 --format terminal)], cwd => $root );
    is $run->{exit}, 6, 'the generator defect sets the internal error exit status';
    like $run->{stderr}, qr/invalid mutant [0-9a-f]+ in lib\/Small[.]pm/, 'the diagnostic identifies the replacement';
    like $run->{stdout}, qr/lib\/Small[.]pm:.*\n(?:.*\n)*?    parse\n    the introduced function max is undefined/m,
      'the terminal report includes the site, cause and function';
};

subtest 'the space rejects a message that no case produces' => sub {
    my $code = "sub read_file (\$path) { open my \$in, '<', \$path or die \"cannot read \$path: \$!\\n\"; return }\n"
      . "sub check (\$n) { die \"the count \$n is too large\\n\" if \$n > 9; return }\n";
    my $messages = Sources::messages($code);
    is [ Invariants::message( $messages, ["mutation: cannot read a.toml: No such file or directory\n"] ) ],
      ["the count $VALUE is too large"], 'the message without a case';
    is [ Invariants::message( $messages, [ "cannot read a: gone\n", "the count 12 is too large\n" ] ) ], [],
      'a case for each message';

    is [ unsaid( [qw(file-unreadable inconclusive)], { inconclusive => 1 } ) ], ['file-unreadable'],
      'the identifier that no case made the code say';
    my %before = %said;
    %said = ();
    heard( 'directory-closed',      "mutation: cannot write report.json: full\n" );
    heard( 'test-directory-closed', "3 mutants\nmutation: cannot run the test in /copy: Permission denied\n" );
    is [ sort keys %said ], ['test-directory-closed'], 'a text counts for the message whose words it holds';
    %said = %before;
};

# The command line: the refusals of the plan, and the refusals while the command runs.
printed($_)
  for ['lst'], [ 'run', 'surplus' ], [ 'mutators', 'surplus' ], ['show'], ['exec'], ['merge'],
  [ '--root', 'absent', 'list' ], [ 'show', 'zzzz' ],
  [ 'show', q{} ], [ 'merge', 'absent.json' ], [ 'merge', 'broken.json' ];

# The command of exec: a name that names nothing, and a directory that the system refuses to run.
my ($mutant) = printed( ['list'] ) =~ /^([0-9a-f]{12})  /m;
printed( [ 'exec', $mutant, q{--}, "$tree/$_" ] ) for 'absent', 'lib';

# The settings on the command line: an option of no command, of another command, without its value, and with one.
printed($_)
  for [ 'list', '--jobz' ], [ 'mutators', '--jobs', 2 ], [ 'list', '--jobs' ], [ 'list', '--cache=1' ],
  [ 'list', '--jobs', 0 ], [ 'list', '--threshold-low', 90 ], [ 'list', '--in-place', '--link', 'vendor' ];
printed( ['list'], cwd => undef );

# The library, the configuration file, and the mutators.
raised( sub { Test::Mutation::mutants( root => $tree, nonesuch => 1 ) } );
for my $text ( "[test]\njobs = 1\n", "root = \"x\"\n", "jobs = = 1\n" ) {
    my $root = directory( 'mutation.toml' => $text );
    raised( sub { Test::Mutation::Settings::of_call( { root => $root } ) } );
}
raised(
    sub { Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => ['nonesuch'], disable => [] ) } );

printed( ['run'], cwd => directory( '.proverc' => "--exec custom-runner\n" ) );
printed( [ 'run', '--source', 'lib/Absent*.pm' ] );
printed( [ 'run', '--perl',   "$tree/absent-perl" ] );
raised( sub { Test::Mutation::Git::changed( Space::git_tree(), 'absent-revision' ) } );
my $selection = Test::Mutation::Select::resolve( config => Test::Mutation::Settings::of_call( { root => $tree } ) );
raised( sub { $selection->verify_copy( directory() ) } );
my $many = directory(
    'lib/Many.pm' => join( "\n", 'package Many;', ( map { "sub item$_ { return \$_[0] + $_ }" } 1 .. 20 ), '1;' ) );
my $mutants = Test::Mutation::mutants( root => $many );
my %prefix;
$prefix{ substr( $_->id, 0, 1 ) }++ for $mutants->@*;
my ($ambiguous) = sort grep { $prefix{$_} > 1 } keys %prefix;
raised( sub { Test::Mutation::Select::by_id( $mutants, $ambiguous ) } );

isa_ok dies { Test::Mutation::Runner::analyze() }, ['Error::TypeTiny'], 'analysis requires a project configuration';
like printed( [ 'run', '--undetected' ], cwd => directory() ), qr/no completed measurement/,
  'an initial recheck names the missing history';
raised(
    sub {
        Test::Mutation::Select::resolve(
            config           => Test::Mutation::Settings::of_call( { root => $tree, mutant => ['deadbeef'] } ),
            historical_paths => { deadbeef => 'lib/Old.pm' }
        );
    }
);

# The comments that suppress mutants: every refusal of the grammar in one file, and the two settings that ask for more.
my $noted = join "\n", 'package Noted;', '## use mutate', 'sub one { return $_[0] + 1 }    ## no mutate (nonesuch)',
  'sub two { return $_[0] - 1 }    ##no mutate', '## no mutate sub', 'my $three = 3 * 3;',
  '## no mutate (regex-anchor)',
  '## no mutate', 'my $four = 4 * 4;', '1;', q{};
raised(
    sub {
        Test::Mutation::Runner::analyze(
            Test::Mutation::Settings::of_call( { root => directory( 'lib/Noted.pm' => $noted ) } ) );
    }
);
Test::Mutation::Suppression::refusals(
    path        => 'lib/Noted.pm',
    suppression => Test::Mutation::Suppression::parse(
        path     => 'lib/Noted.pm',
        comments => [ { line => 1, own => 0, text => '## no mutate', routine => undef } ]
    ),
    mutants        => [],
    require_names  => 1,
    require_reason => 1,
);

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
    raised( sub { Test::Mutation::Report::Json::parse($broken) } );
}

# The files of a run: a record that is gone, a report that has no place, a file that fails to close, and a cache in the way.
symlink "$scratch/nowhere", "$scratch/gone.rec" or die "symlink: $!";
raised( sub { Test::Mutation::Record::read_directory($scratch) } );
unlink "$scratch/gone.rec" or die "unlink: $!";
{
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub { return Samples::result( statuses => ['Survived'] ) };
    printed( [ 'run', '--format', 'terminal', '--github' ],
        env => { GITHUB_STEP_SUMMARY => "$tree/absent/summary.md" } );
}
{
    my %named = ( config => { value => 'ci.toml', spelled => '--config', surface => 'line' } );
    local $failing{close} = 1;
    raised(
        sub {
            Test::Mutation::Settings::configure(
                root  => $tree,
                given => { origin     => 'line', name => undef, entries => \%named },
                facts => { processors => 1, env => {} }
            );
        }
    );
}
mkdir "$scratch/cache.json" or die "mkdir: $!";
raised( sub { Test::Mutation::Store::save( "$scratch/cache.json", {} ) } );

# The copy of a tree: each step that the system may refuse.
my $from = directory( 'dir/file.txt' => 'x', 'linked/file.txt' => 'y' );
copied( "$scratch/absent", "$scratch/copy-of-nothing" );
copied( $from, directory( 'in-the-way' => 'a file' ) . '/in-the-way/copy' );
copied( $from, directory( 'linked'     => 'a file' ), 'linked' );
{
    no warnings 'redefine';
    local *File::Copy::copy = sub { $! = 13; return 0 };    ## no critic (Variables::RequireLocalizedPunctuationVars)
    copied( $from, "$scratch/copy-without-content" );
}
{
    no warnings 'redefine';
    local *Time::HiRes::utime = sub { $! = 1; return 0 };    ## no critic (Variables::RequireLocalizedPunctuationVars)
    copied( $from, "$scratch/copy-without-time" );
}
{
    local $failing{chmod} = 1;
    copied( $from, "$scratch/copy-without-mode" );
    raised( sub { Test::Mutation::Tree::remove( directory( 'file.txt' => 'x' ) ) } );
}
{
    local $failing{rmdir} = 1;
    raised( sub { Test::Mutation::Tree::remove( directory() ) } );
}
{
    no warnings 'redefine';
    local *Test::Mutation::Tree::copy =
      sub { Test::Mutation::Error::raise( 'directory-missing', path => 'the project' ) };
    raised(
        sub {
            Test::Mutation::Runner::run( Test::Mutation::Settings::of_call( { root => $tree } ), sub { } );
        }
    );
}

# Git: a command that fails, a machine without it, and a command that fails without a word.
{
    local $ENV{PATH} = directory();
    heard( 'git-unstartable', raised( sub { Test::Mutation::Git::changed( $tree, 'HEAD' ) } ) );
}
{
    my $silent = directory( 'git' => "#!/bin/sh\nexit 3\n" );
    CORE::chmod( oct '755', "$silent/git" ) or die "chmod: $!";
    local $ENV{PATH} = $silent;
    raised( sub { Test::Mutation::Git::changed( $tree, 'HEAD' ) } );
}

# The pool: a process, a pipe, and the three steps of a test before its first line.
{
    local $failing{fork} = 1;
    pooled();
}
{
    local $failing{pipe} = 1;
    pooled();
}
{
    local $failing{close} = 1;
    pooled();
}
heard( 'test-directory-closed', on_standard_error( sub { pooled( cwd => "$scratch/absent" ) } ) );
{
    # The child of the pool inherits the replaced function, so its standard streams stay those of this file.
    no warnings 'redefine';
    local *POSIX::dup2 = sub (@) { $! = 9; return };    ## no critic (Variables::RequireLocalizedPunctuationVars)
    heard( 'test-streams-unset', on_standard_error( sub { pooled() } ) );
}
heard( 'command-unstartable', pooled( command => ["$scratch/no-such-program"] ) );

# The defects of the tool: an error without a type, a message with other values, a shim without its lines, and a verdict.
{
    no warnings 'redefine';
    local *Test::Mutation::Runner::analyze = sub { die "the analysis broke\n" };
    printed( ['list'] );
}
heard( 'message-slots', raised( sub { Test::Mutation::Message::text_of( 'inconclusive', reason => 'none' ) } ) );
raised( sub { Test::Mutation::Message->new( Test::Mutation::Message::row('inconclusive')->%*, colour => 'red' ) } );
{
    local @INC = ( directory( 'Test/Mutation/Shim.pm' => "1;\n" ) );
    raised( sub { Test::Mutation::Runner::shim_text(3) } );
}
{
    local @INC = ( directory() );
    raised( sub { Test::Mutation::Runner::shim_text(3) } );
}
raised(
    sub {
        Test::Mutation::Verdict::step( Test::Mutation::Verdict::start(),
            { test => 't/a.t', result => 'fail', served => 1, load_failed => 1, bypassed => 0, syntax => undef } );
    }
);

# The outcomes of a run that is no success: each one ends standard error with its line.
my $failure = { test => 't/a.t', output => "not ok 1\n", errors => q{} };
for my $case (
    [ [ statuses => [qw(Killed Survived)] ], '--min-score', 100 ],
    [ [ statuses => [], baseline_failures => [$failure] ] ],
    [ [ statuses => ['NoVerdict'] ] ],
    [ [ statuses => [qw(Killed Pending)], interrupted => 'TERM' ] ],
  )
{
    my ( $result, @line ) = $case->@*;
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub { return Samples::result( $result->@* ) };
    printed( [ 'run', '--config', 'ci.toml', '--format', 'terminal', @line ] );
}

# The shim says the lines of its two messages itself, in a process of its own.
heard( 'spec-unreadable', shim_says( "$scratch/absent.spec", q{} ) );
heard( 'spec-unclosable', shim_says( "$tree/ci.toml",        'BEGIN { *CORE::GLOBAL::close = sub { return !1 } }' ) );

# The warnings of a run, each from a project that calls for it.
my $module = "package Small;\nuse strict;\nuse warnings;\nsub next_one { return \$_[0] + 1 }\n"
  . "sub size { return \$_[0] > 5 ? 'big' : 'small' }\n1;\n";
my $test = "use Test::More tests => 1;\nuse Small;\nis Small::next_one(2), 3, 'the next one';\n";

subtest 'the CLI reports an inconsistent cached verdict and returns status four' => sub {
    local $ENV{MUTATION_CHECK_SUM} = "$scratch/check-sum";
    my $root = directory(
        'lib/Small.pm' => "package Small;\nsub plus { return \$_[0] + 1 }\n1;\n",
        't/small.t'    => <<'PERL',
use Test::More tests => 1;
use Small;
my $sum = Small::plus(2);
if ( -f $ENV{MUTATION_CHECK_SUM} ) { is $sum, 3, 'the sum' }
else { pass 'the addition ran' }
PERL
    );
    my @command = qw(run --jobs 1 --no-equivalence --format terminal);
    is World::observe( \@command, cwd => $root )->{exit}, 0, 'the first measurement passes';
    open my $check, '>', $ENV{MUTATION_CHECK_SUM} or die $!;
    CORE::close($check) or die $!;
    my $changed = World::observe( \@command, cwd => $root );
    is $changed->{exit}, 4, 'a discrepancy prevents a successful gate';
    like $changed->{stdout} . $changed->{stderr}, qr/cached verdict for [0-9a-f]{12} differs from a fresh measurement/,
      'the warning identifies a measured mutant';
};

# Places that the analysis leaves out, in a project without a test.
my $crlf =
  "package Small;\r\nuse strict;\r\nmy \$NOTE = \"two\r\nlines\";\r\nsub next_one { return \$_[0] + 1 }\r\n1;\r\n";
measured( { 'lib/Once.pm' => $crlf, 'lib/Twice.pm' => $crlf =~ s/1;\r\n\z/my \$MORE = "a\r\nb";\r\n1;\r\n/r } );

# An external lock covers one test of a mutant or two tests of the original.
{
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    local $ENV{MUTATION_TEST_LOCK} = "$directory/resource";
    my $resource = Test::Mutation::Source::read_bytes('t/fixtures/exclusive/t/resource.t');
    my %files    = (
        'lib/Exclusive.pm' => Test::Mutation::Source::read_bytes('t/fixtures/exclusive/lib/Exclusive.pm'),
        't/a.t'            => $resource
    );
    my %pair  = ( %files, 't/b.t' => $resource );
    my @cases = ( [ \%files, 3, 'mutants' ], [ \%pair, 2, 'originals' ] );
    for my $case (@cases) {
        my ( $project, $jobs, $phase ) = @$case;
        local $ENV{MUTATION_TEST_OVERLAP} = $phase;
        measured( $project, jobs => $jobs, equivalence => 0, timeout_floor => 30 );
    }
}

# The module Bound needs its application's initialization and the module Empty stops the deparser before it writes anything.
my $bound = "package Bound;\nuse strict;\nuse warnings;\nBEGIN { die \"no application\\n\" if !\$main::APPLICATION }\n"
  . "sub size { return 10 > 5 ? 'big' : 'small' }\n1;\n";
measured(
    {
        'lib/Small.pm' => $module,
        'lib/Bound.pm' => $bound,
        'lib/Empty.pm' =>
          "package Empty;\nuse File::Spec;\nBEGIN { open STDOUT, '>', File::Spec->devnull if \$0 =~ /Empty[.]pm\\z/ }\nsub high { return 10 > 5 }\n1;\n",
        't/empty.t'  => "use Test::More tests => 1;\nuse Empty;\nok Empty::high(), 'a true result';\n",
        't/direct.t' => "use Test::More tests => 1;\nuse Cwd ();\nrequire( Cwd::getcwd() . '/lib/Small.pm' );\n"
          . "is Small::next_one(2), 3, 'the next one';\n",
        't/bound.t' => "use Test::More tests => 1;\nBEGIN { \$main::APPLICATION = 1 }\nuse Bound;\n"
          . "is Bound::size(), 'big', 'a size';\n",
    },
    in_place => 1,
);

# A work directory that resists removal.
{
    no warnings 'redefine';
    local *Test::Mutation::Tree::remove = sub (@) { die "stuck\n" };
    measured( { 'lib/Small.pm' => $module, 't/small.t' => $test }, in_place => 1 );
}

# A mutant that leaves a file in the project, which breaks another test from then on.
my $writer =
    "use Test::More tests => 1;\nuse Small;\nmy \$next = Small::next_one(2);\n"
  . "if ( \$next != 3 ) { open my \$out, '>', 'left-behind.txt' or die \$!; close \$out }\n"
  . "is \$next, 3, 'the next one';\n";
my $reader = "use Test::More tests => 2;\nuse Small;\nok !-e 'left-behind.txt', 'no file is in the way';\n"
  . "is Small::size(9), 'big', 'a size';\n";
measured( { 'lib/Small.pm' => $module, 't/reader.t' => $reader, 't/writer.t' => $writer }, in_place => 1 );

my %builder_files = ( 'lib/Small.pm' => $module, 't/small.t' => $test, '.proverc' => "-b\n" );
like raised( sub { measured( { %builder_files, 'Native.xs' => "/* native */\n" } ) } ), qr/Makefile[.]PL.*Build[.]PL/,
  'an XS source needs a build recipe';
like raised( sub { measured( { %builder_files, 'Build.PL' => "die qq{broken builder\\n};\n" } ) } ),
  qr/Build[.]PL.*broken builder/, 'the configure diagnostic reaches the caller';
{
    my $root = directory( %builder_files, 'blib/lib/Small.pm' => $module );
    utime 1000, 1000, "$root/blib/lib/Small.pm" or die "utime: $!";
    my $config = Test::Mutation::Settings::of_call( { root => $root, in_place => 1 } );
    like raised(
        sub {
            Test::Mutation::Runner::run( $config, sub (@) { return } );
        }
      ),
      qr{blib/lib/Small[.]pm.*make}, 'in-place mode identifies an old product';
}

{
    my $root            = directory( %builder_files, 'blib/lib/Small.pm' => "# generated\n$module" );
    my $config          = Test::Mutation::Settings::of_call( { root => $root } );
    my $build_selection = Test::Mutation::Select::resolve( config => $config );
    my $build_mutant    = $build_selection->mutants->[0];
    my $exec_failure    = raised(
        sub {
            Test::Mutation::Runner::run_command( $config, $build_selection->sources->{ $build_mutant->path },
                $build_mutant, [ $^X, '-e', 'exit 0' ] );
        }
    );
    like $exec_failure, qr{blib/lib/Small[.]pm.*private build.*lib/Small[.]pm},
      'exec identifies both the unchanged generated product and the selected source';
}

my @unsaid = unsaid( \@catalog, \%said );
Gate::findings( 'contract-message-messages', [ map { "no case produces the message $_" } @unsaid ] );
Gate::checked( 'messages of the catalog',       scalar @catalog,    at_least => 86 );
Gate::checked( 'messages that a case produces', @catalog - @unsaid, at_least => 86 );

done_testing;
