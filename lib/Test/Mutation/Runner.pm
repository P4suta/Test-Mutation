package Test::Mutation::Runner;
use v5.36;
use Cwd             ();
use Digest::SHA     ();
use Errno           ();
use File::Basename  ();
use File::Find      ();
use File::Spec      ();
use List::Util      ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef Bool CodeRef Dict HashRef InstanceOf Int Maybe Optional Str Tuple);
use Type::Params    qw(signature_for);
use Test::Mutation::Cache;
use Test::Mutation::Coverage;
use Test::Mutation::Diff;
use Test::Mutation::Error;
use Test::Mutation::Git;
use Test::Mutation::Message;
use Test::Mutation::Mutant::Generator;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Pool;
use Test::Mutation::Project;
use Test::Mutation::Record;
use Test::Mutation::Result;
use Test::Mutation::Signals;
use Test::Mutation::Source;
use Test::Mutation::Status;
use Test::Mutation::Suppression;
use Test::Mutation::Syntax::PPI;
use Test::Mutation::Tree;
use Test::Mutation::Types qw(PathSelection);
use Test::Mutation::Try;
use Test::Mutation::Verdict;

our $VERSION = '0.001';

my $SHIM_FILE     = 'Test/Mutation/Shim.pm';
my %UNDETECTED    = map { $_->name => 1 } grep { $_->role eq 'undetected' } Test::Mutation::Status::rows()->@*;
my $CHANGES_NAMED = 5;
my $TYPED         = InstanceOf ['Test::Mutation::Error'];
my $INTERRUPTION  = InstanceOf ['Test::Mutation::Interrupted'];

# A test that prints a quarter of a gigabyte prints without end, as a loop that warns does, and the pool ends it.
# The bytes stay in no file, and a test that prints a hundred megabytes and then fails still fails on its own.
my $OUTPUT_LIMIT = 268_435_456;

my $ANALYSIS = Dict [
    sources   => HashRef [ InstanceOf ['Test::Mutation::Source'] ],
    mutants   => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ],
    problems  => ArrayRef [ Dict [ path => Str, problem => Str ] ],
    left_out  => HashRef [Int],
    rejected  => ArrayRef [ Dict [ path => Str, mutator => Str, line => Int, rule => Str ] ],
    inventory => Dict [ mutants => Int, digest => Str ],
];

signature_for analyze =>
  ( positional => [ InstanceOf ['Test::Mutation::Config'], Optional [ Maybe [PathSelection] ] ], returns => $ANALYSIS );

sub analyze ( $config, $paths = undef ) {
    my $root = Cwd::abs_path( $config->root );
    return _analysis( $config, $root, $root, { paths => $paths } );
}

# Git answers for the project, and the files come from the tree that the tests run in.
sub _analysis ( $config, $project, $root, $options ) {
    my $paths    = $options->{paths};
    my $mutators = Test::Mutation::Mutator::Catalog::choose(
        profile => $config->profile,
        enable  => $config->enable,
        disable => $config->disable,
    );

    # A comment may name a mutator that the run leaves out, so the mutants of every mutator decide whether it suppresses one.
    my %chosen = map { $_->name => 1 } $mutators->@*;
    my $others = [ grep { !$chosen{ $_->name } } Test::Mutation::Mutator::Catalog::mutators()->@* ];
    my ( %sources, %left_out, @mutants, @problems, @rejected, @refusals );
    my %only    = map { $_ => 1 } $config->mutant->@*;
    my $changed = defined $config->since    ? Test::Mutation::Git::changed( $project, $config->since ) : undef;
    my $perl    = $options->{baseline_only} ? undef : _perl_version( $config->perl );
    for my $path ( Test::Mutation::Project::files( $root, $config->source, $config->source_exclude )->@* ) {
        next if $changed && !$changed->{$path};
        next if $paths   && !exists $paths->{$path};
        my $source = Test::Mutation::Source->from_bytes( path => $path, bytes => _slurp("$root/$path") );
        if ( $options->{baseline_only} ) {
            $sources{$path} = $source;
            next;
        }
        my $analysis = Test::Mutation::Syntax::PPI::analyze($source);

        # The analysis of a file is the longest step outside the tests, so a signal ends the work after the file it met.
        Test::Mutation::Signals::check();
        if ( defined $analysis->{problem} ) {
            push @problems, { path => $path, problem => $analysis->{problem} };
            next;
        }
        $sources{$path}  = $source;
        $left_out{$path} = scalar $analysis->{dropped}->@* if $analysis->{dropped}->@*;
        my $generated = Test::Mutation::Mutant::Generator::generate(
            source   => $source,
            analysis => $analysis,
            mutators => $mutators,
            perl     => $perl
        );
        my $judged = Test::Mutation::Mutant::Generator::generate(
            source   => $source,
            analysis => $analysis,
            mutators => $others,
            perl     => $perl
        );
        push @refusals,
          Test::Mutation::Suppression::refusals(
            path           => $path,
            suppression    => $analysis->{suppressions},
            mutants        => [ map { $_->{mutants}->@* } $generated, $judged ],
            require_names  => $config->suppress_require_names,
            require_reason => $config->suppress_require_reason,
          )->@*;
        push @mutants, grep { !$paths || !$paths->{$path}->@* || _in_changed_lines( $paths->{$path}, $_ ) }
          grep { !$changed || _in_changed_lines( $changed->{$path}, $_ ) }
          grep { !%only || $only{ $_->id } } $generated->{mutants}->@*;
        push @rejected, map { { path => $path, $_->%* } } $generated->{rejected}->@*;
    }

    # A run with a broken comment would measure other mutants than the comments ask for, so it measures none.
    Test::Mutation::Error::raise( 'suppressions-invalid', list => join q{; }, map { $_->{text} } @refusals )
      if @refusals;
    my $inventory =
      { mutants => scalar @mutants, digest => Digest::SHA::sha256_hex( join "\n", map { $_->id } @mutants ) };
    if ( defined $config->shard ) {
        my ( $part, $parts ) = split m{/}, $config->shard;
        @mutants = @mutants[ grep { $_ % $parts == $part - 1 } 0 .. $#mutants ];
    }
    return {
        sources   => \%sources,
        mutants   => \@mutants,
        problems  => \@problems,
        left_out  => \%left_out,
        rejected  => \@rejected,
        inventory => $inventory
    };
}

# The version of the interpreter that runs the tests, which may be another one than this interpreter.
sub _perl_version ($perl) {
    return 0 + $] if $perl eq $^X;
    no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    open my $answer, q{-|}, $perl, '-e', 'print $]' or return;
    my $version = readline $answer;
    close $answer or return;
    return defined $version && $version =~ /\A[0-9]+(?:[.][0-9]+)?\z/ ? 0 + $version : undef;
}

sub _in_changed_lines ( $ranges, $mutant ) {
    my ( $first, $last ) = ( $mutant->from->[0], $mutant->to->[0] );

    # An end at the first column of a line leaves that line outside the mutant.
    $last-- if $mutant->to->[1] == 1;
    return Test::Mutation::Diff::touches( $ranges, $first, $last );
}

signature_for run => (
    positional => [
        InstanceOf ['Test::Mutation::Config'],
        CodeRef,
        Dict [ paths => Optional [ Maybe [PathSelection] ], baseline_only => Optional [Bool] ],
        { default => sub { {} } }
    ],
    returns => InstanceOf ['Test::Mutation::Result'],
);

sub run ( $config, $listener, $options = {} ) {
    my $started = Time::HiRes::time();
    my $project = Cwd::abs_path( $config->root );
    my $run     = {
        config   => $config,
        options  => $options,
        project  => $project,
        root     => $project,
        listener => $listener,
        jobs     => $config->jobs,
        sequence => 0,
        taint    => {},
        warnings => {},
        free     => {},
        stats    => { map { $_ => 0 } qw(copies walks compiles spawns listings baseline_tests verifications) },
    };
    my $measure = sub {
        _copy_project($run) if !$config->in_place;
        return _measure( $run, $started );
    };
    my $release = sub { _discard( $run->{copies} ) if defined $run->{copies}; return };
    return Test::Mutation::Signals::watch( sub { Test::Mutation::Try::with_cleanup( $measure, $release ) } );
}

# The tests run in a copy of the project, so a file that a test writes or removes leaves the project as it was.
sub _copy_project ($run) {
    my $config  = $run->{config};
    my $project = $run->{project};
    $run->{name} = File::Basename::basename($project);

    $run->{copies} = Cwd::abs_path( Test::Mutation::Tree::temporary( File::Spec->tmpdir, 'mutation-' ) );

    # A temporary directory inside the project holds the copies, which are no part of a copy.
    my @skip =
      ( q{.git}, map { _inside( $project, $_ ) } $config->cache_dir, $config->report_dir, $run->{copies} );
    my $copied =
      Test::Mutation::Try::attempt( sub { $run->{root} = _new_copy( $run, $project, \@skip, $config->link ) } );
    return if exists $copied->{value};

    # A failure of the system names its path, and the run adds what the user can do about it.
    my $error = $copied->{error};
    die $error if !$TYPED->check($error);    ## no critic (ErrorHandling::RequireCarping)
    return Test::Mutation::Error::raise( 'project-uncopyable', reason => $error->message );
}

# The path from the project to a place inside it, and nothing for a place outside.
sub _inside ( $project, $path ) {
    my $absolute = File::Spec->canonpath( File::Spec->rel2abs( $path, $project ) );
    my $prefix   = "$project/";
    return substr( $absolute, 0, length $prefix ) eq $prefix ? substr $absolute, length $prefix : ();
}

# Each copy has the name of the project inside a directory of its own.
sub _new_copy ( $run, $from, $skip, $link ) {
    my $to = Test::Mutation::Tree::temporary( $run->{copies}, q{} ) . "/$run->{name}";
    Test::Mutation::Tree::copy( from => $from, to => $to, skip => $skip, link => $link );
    $run->{stats}{copies}++;
    return $to;
}

sub _walk ( $run, $root, @skip ) {
    $run->{stats}{walks}++;
    return Test::Mutation::Tree::snapshot( root => $root, skip => \@skip );
}

# Every mutant starts from the state that the unmodified run left, so each job works in a copy of its own.
# A job takes a copy that no job uses, or a new one, and records the state it finds.
sub _job_root ( $run, $job ) {
    return $run->{root} if !defined $run->{copies};
    if ( !$job->{copy} ) {
        my ($free) = sort keys $run->{free}->%*;
        my $root = defined $free ? $free : _new_copy( $run, $run->{root}, [], [] );
        delete $run->{free}{$root};
        $job->{copy} = { root => $root, state => _walk( $run, $root ) };
    }
    return $job->{copy}{root};
}

# A mutant may leave a changed copy behind, so the copy returns to its state before the next job takes it.
# A copy that fails to return stays out of use, and the next job makes a new one.
sub _release ( $run, $job ) {
    my $copy    = delete $job->{copy} or return;
    my $root    = $copy->{root};
    my $changes = Test::Mutation::Tree::changes( $copy->{state}, _walk( $run, $root ) );
    my $restore = sub { Test::Mutation::Tree::restore( from => $run->{root}, to => $root, changes => $changes ) };
    return if $changes->@* && exists Test::Mutation::Try::attempt($restore)->{error};
    $run->{free}{$root} = 1;
    return;
}

# A test may leave a directory without any right, and such a leftover must not end the run.
sub _discard (@paths) {
    return scalar grep {
        my $path = $_;
        exists Test::Mutation::Try::attempt( sub { Test::Mutation::Tree::remove($path) } )->{error}
    } @paths;
}

sub _measure ( $run, $started ) {
    my $config   = $run->{config};
    my $listener = $run->{listener};
    my $root     = $run->{root};
    my $analysis = _analysis( $config, $run->{project}, $root, $run->{options} );
    my @tests    = Test::Mutation::Project::files( $root, $config->test, $config->test_exclude )->@*;
    my @active   = grep { !$_->suppressed } $analysis->{mutants}->@*;
    my %targets  = map  { $_->path => 1 } @active;
    $run->{sources} = $analysis->{sources};

    for my $path ( sort keys $analysis->{left_out}->%* ) {
        my $count = $analysis->{left_out}{$path};
        _warn( $run,
            $count == 1
            ? Test::Mutation::Message::warning( 'analysis-left-out-place',  path => $path )
            : Test::Mutation::Message::warning( 'analysis-left-out-places', path => $path, count => $count ) );
    }
    $listener->( 'analyzed',
        { mutants => scalar(@active), files => scalar( keys %targets ), tests => scalar(@tests) } );

    my %result = (
        root              => $run->{project},
        sources           => { map { $_ => $analysis->{sources}{$_}->text } keys $analysis->{sources}->%* },
        tests             => [],
        entries           => [],
        problems          => $analysis->{problems},
        baseline_failures => [],
        parallel_safe     => 1,
        shard             => $config->shard,
        inventory         => $analysis->{inventory},
        started           => $started,
    );

    if ( ( @active || $run->{options}{baseline_only} ) && @tests ) {
        my $measure = sub {
            _prepare_work($run);
            $run->{targets} = [ sort keys $analysis->{sources}->%* ];
            my $baseline = _baseline( $run, \@tests, $run->{targets} );
            my %measured = (
                parallel_safe     => $baseline->{parallel_safe},
                baseline_failures => $baseline->{failures},
                tests             => [
                    map { { name => $_, duration => $baseline->{tests}{$_}{duration} } }
                    sort keys $baseline->{tests}->%*
                ],
            );
            if ( !$baseline->{failures}->@* ) {
                $listener->( 'baseline', { tests => scalar(@tests), jobs => $run->{jobs} } );
                if ( !$run->{options}{baseline_only} ) {
                    $run->{tree} = _tree($run) if !defined $run->{copies};
                    $measured{entries} = _mutants( $run, $analysis->{mutants}, $baseline );
                }
            }
            return \%measured;
        };
        my $leave = sub {
            _warn( $run, Test::Mutation::Message::warning( 'work-directory-stays', path => $run->{work} ) )
              if !$config->keep_work && _leave_work($run);
            return;
        };
        %result = ( %result, Test::Mutation::Try::with_cleanup( $measure, $leave )->%* );
    }
    else {
        _warn( $run, Test::Mutation::Message::warning('tests-unmatched') )
          if ( @active || $run->{options}{baseline_only} ) && !@tests;
        $result{entries} =
          [ map { $_->suppressed ? _suppressed($_) : _entry( $_, 'NoCoverage', 'unreached', undef, undef, [], 0, 0 ) }
              $analysis->{mutants}->@* ];
    }

    return Test::Mutation::Result->new(
        %result,
        warnings    => [ sort keys $run->{warnings}->%* ],
        jobs        => $run->{jobs},
        interrupted => $run->{interrupted},
        reused      => $run->{reused} || 0,
        in_copies   => defined $run->{copies} ? 1 : 0,
        finished    => Time::HiRes::time(),
        stats       => $run->{stats},
    );
}

sub _slurp ($path) {
    open my $handle, '<:raw', $path or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    local $/ = undef;
    my $content = readline $handle;
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return $content // q{};
}

sub _spew ( $path, $content ) {
    open my $handle, '>:raw', $path or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
    print {$handle} $content or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
    close $handle            or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return;
}

sub _entry ( $mutant, $status, $reason, $detail, $by, $covered_by, $tests_run, $duration ) {
    return {
        mutant     => $mutant,
        status     => $status,
        reason     => $reason,
        detail     => $detail,
        by         => $by,
        covered_by => $covered_by,
        tests_run  => $tests_run,
        duration   => $duration,
    };
}

sub _suppressed ($mutant) {
    my $reason = $mutant->suppression_reason;
    my $detail = 'suppressed by a comment' . ( defined $reason ? ": $reason" : q{} );
    return _entry( $mutant, 'Ignored', 'suppressed', $detail, undef, [], 0, 0 );
}

# Tasks end in an order that changes from run to run, so the warnings form a set that the result sorts.
sub _warn ( $run, $text ) {
    $run->{warnings}{$text} = 1;
    return;
}

# The work directory leaves the project with its last file, and a cache or a kept run holds it there.
sub _leave_work ($run) {
    my $stuck = defined $run->{work} ? _discard( $run->{work} ) : 0;

    # A directory that still holds a file refuses to go, which is the wanted result.
    rmdir $run->{project} . q{/} . $run->{config}->cache_dir;
    return $stuck;
}

sub _prepare_work ($run) {
    my $base = $run->{project} . q{/} . $run->{config}->cache_dir;

    Test::Mutation::Tree::make($base);
    my $work = Test::Mutation::Tree::temporary( $base, 'run-' );

    # The run owns the directory from here on, so a failure below still removes it.
    $run->{work} = $work;
    my $outer      = $ENV{TEST_MUTATION_GENERATION};
    my $generation = defined $outer ? $outer + 1 : 1;
    Test::Mutation::Tree::make( map { "$work/$_" } 'shim/Test/Mutation/Shim', 'mutants', 'records', 'tmp' );
    _spew( "$work/shim/Test/Mutation/Shim/G$generation.pm", shim_text($generation) );
    $run->{generation} = $generation;
    $run->{package}    = "Test::Mutation::Shim::G$generation";
    return;
}

signature_for shim_text => ( positional => [Str], returns => Str );

sub shim_text ($generation) {
    my $text    = _module_text($SHIM_FILE);
    my $renamed = $text =~ s/^package Test::Mutation::Shim;$/package Test::Mutation::Shim::G$generation;/m;
    my $marked  = $text =~ s/^my \$GENERATION = 0;$/my \$GENERATION = $generation;/m;
    die Test::Mutation::Message::text_of( 'shim-unprepared', generation => $generation ) . "\n"
      if !$renamed || !$marked;
    return $text;
}

sub _module_text ($file) {
    for my $entry (@INC) {
        if ( ref $entry eq 'CODE' ) {
            my @served = $entry->( $entry, $file );
            next          if !@served;
            shift @served if ref $served[0] eq 'SCALAR';
            my $handle = shift @served;
            next if ref $handle ne 'GLOB';
            my $filter = ref $served[0] eq 'CODE' ? $served[0] : undef;
            my $text   = q{};
            while ( defined( my $line = readline $handle ) ) {
                if ($filter) {
                    local $_ = $line;
                    $filter->();
                }
                $text .= $line;
            }
            if ($filter) {
                local $_ = q{};
                $filter->();
            }
            return $text;
        }
        next                          if ref $entry;
        return _slurp("$entry/$file") if -f "$entry/$file";
    }
    die Test::Mutation::Message::text_of( 'shim-missing', file => $file ) . "\n";
}

sub _taint_switch ( $run, $test ) {
    if ( !exists $run->{taint}{$test} ) {
        open my $handle, '<', "$run->{root}/$test"
          or Test::Mutation::Error::raise( 'file-unreadable', path => $test, reason => "$!" );
        my $first = readline $handle;
        close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $test, reason => "$!" );
        $run->{taint}{$test} = defined $first && $first =~ /\A[#]!.*perl.*\s-\w*([Tt])/ ? "-$1" : undef;
    }
    return $run->{taint}{$test};
}

sub _spec ( $run, $name, $trace, $targets ) {
    my $path  = "$run->{work}/$name.spec";
    my @lines = ( "trace\t" . ( $trace ? 1 : 0 ), map { join "\t", 'target', $_->@* } $targets->@* );
    _spew( $path, join q{}, map { "$_\n" } @lines );
    return $path;
}

sub _inherited ($name) {
    my $value = $ENV{$name};
    return defined $value && length $value ? ($value) : ();
}

sub _environment ( $run, $spec, $root ) {
    my $generation = $run->{generation};
    return (
        "TEST_MUTATION_SPEC_G$generation" => $spec,
        TEST_MUTATION_GENERATION          => $generation,
        TEST_MUTATION_ROOT                => $root,
        PERL5OPT                          => join( q{ }, _inherited('PERL5OPT'), '-M' . $run->{package} ),
        PERL5LIB                          => join( q{:}, "$run->{work}/shim",    _inherited('PERL5LIB') ),
    );
}

signature_for target_pairs => (
    positional => [ Str, ArrayRef [Str], Str, Str ],
    returns    => ArrayRef [ Tuple [ Str, Str ] ],
);

sub target_pairs ( $root, $paths, $mutated, $file ) {
    my %listed = map { $_ => 1 } $paths->@*;
    my @paths  = ( $paths->@*, $listed{$mutated} ? () : $mutated );
    return [ map { [ "$root/$_", $_ eq $mutated ? $file : "$root/$_" ] } @paths ];
}

sub _write_mutant ( $run, $source, $mutant, $root ) {
    my $file = "$run->{work}/mutants/" . $mutant->id . '.pm';
    _spew( $file, $source->to_bytes( $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement ) ) );
    my $targets = target_pairs( $root, $run->{targets} ? $run->{targets} : [], $mutant->path, $file );
    my $spec    = _spec( $run, 'mutants/' . $mutant->id, 0, $targets );
    return ( $file, $spec );
}

signature_for run_command => (
    positional => [
        InstanceOf ['Test::Mutation::Config'],
        InstanceOf ['Test::Mutation::Source'],
        InstanceOf ['Test::Mutation::Mutant'],
        ArrayRef [Str]
    ],
    returns => Int,
);

sub run_command ( $config, $source, $mutant, $command ) {
    my $root = Cwd::abs_path( $config->root );
    my $run  = { config => $config, project => $root, root => $root };
    my $work = sub {
        _prepare_work($run);
        my ( undef, $spec ) = _write_mutant( $run, $source, $mutant, $root );
        local %ENV = ( %ENV, _environment( $run, $spec, $root ) );

        # A command that cannot start ends exec with one line of the tool, and the warning of Perl would add another.
        no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        my $status = system { $command->[0] } $command->@*;

        # As with env, a name that names nothing differs from a program that the system refuses to run.
        my $missing = $! == Errno::ENOENT();
        return [ $status, $missing, "$!" ];
    };

    # A signal for the tool alone waits while the command runs, and it ends the work once the work directory is gone.
    my $ran = Test::Mutation::Signals::watch(
        sub {
            Test::Mutation::Try::with_cleanup( $work, sub { _leave_work($run) } );
        }
    );
    my ( $status, $missing, $reason ) = $ran->@*;
    if ( $status == -1 ) {
        Test::Mutation::Error::raise( 'command-not-found',    command => $command->[0], reason => $reason ) if $missing;
        Test::Mutation::Error::raise( 'command-not-runnable', command => $command->[0], reason => $reason );
    }
    return 128 + ( $status & 127 ) if $status & 127;
    return $status >> 8;
}

# prove names its library directories in full, so a test may change its directory before it loads a module.
sub _switches ( $run, $root ) {
    return map { s{\A-I(?=[^/])}{-I$root/}r } $run->{config}->switch->@*;
}

sub _test_task ( $run, %arg ) {
    my $sequence   = ++$run->{sequence};
    my $work       = $run->{work};
    my $generation = $run->{generation};
    my $record     = "$work/records/$sequence";
    my $tmp        = "$work/tmp/$sequence";
    Test::Mutation::Tree::make( $record, $tmp );
    my $taint = _taint_switch( $run, $arg{test} );
    my $load  = '-M' . $run->{package};
    return {
        command => [
            $run->{config}->perl,     _switches( $run, $arg{root} ),
            ( $taint ? $taint : () ), "-I$work/shim",
            $load,                    $arg{test},
        ],
        env => {
            _environment( $run, $arg{spec}, $arg{root} ),
            "TEST_MUTATION_RECORD_G$generation" => $record,
            HARNESS_ACTIVE                      => 1,
            PWD                                 => $arg{root},
            TMPDIR                              => $tmp,
        },
        cwd             => $arg{root},
        timeout         => $arg{timeout},
        output_limit    => $OUTPUT_LIMIT,
        stop_on_failure => $arg{stop_on_failure},
        payload         => { $arg{payload}->%*, test => $arg{test}, record => $record, tmp => $tmp },
    };
}

sub _collect ($task) {
    my $payload = $task->{payload};
    my $record  = Test::Mutation::Record::read_directory( $payload->{record} );
    _discard( $payload->{record}, $payload->{tmp} );
    return $record;
}

# Runs tests against the unmodified sources, which the hook serves as it serves a mutant.
# `counted` names the count of the work that the runs of these tests add to.
sub _unmodified ( $run, $name, $trace, $jobs, $tests, $counted ) {
    my $root  = $run->{root};
    my $spec  = _spec( $run, $name, $trace, [ map { [ "$root/$_", "$root/$_" ] } $run->{targets}->@* ] );
    my @queue = $tests->@*;
    my %outcome;
    Test::Mutation::Pool::run(
        jobs => $jobs,
        work => $run->{stats},
        next => sub {
            my $test = shift @queue or return;
            $run->{stats}{$counted}++;
            return _test_task(
                $run,
                root            => $root,
                test            => $test,
                spec            => $spec,
                timeout         => $run->{config}->baseline_timeout,
                stop_on_failure => 0,
                payload         => {},
            );
        },
        done => sub ( $task, $result ) {
            $outcome{ $task->{payload}{test} } = { result => $result, record => _collect($task) };
            return;
        },
    );
    return \%outcome;
}

sub _baseline ( $run, $tests, $targets ) {
    my $root = $run->{root};
    my $pass = sub ( $jobs, $names, $counted ) {
        return _unmodified( $run, 'baseline', $run->{config}->coverage eq 'line', $jobs, $names, $counted );
    };

    my $outcome       = $pass->( $run->{jobs}, $tests, 'baseline_tests' );
    my @failed        = grep { !$outcome->{$_}{result}{passed} } $tests->@*;
    my $parallel_safe = 1;
    if ( @failed && $run->{jobs} > 1 ) {
        my $serial = $pass->( 1, \@failed, 'verifications' );
        $outcome->{$_} = $serial->{$_} for @failed;
        @failed = grep { !$outcome->{$_}{result}{passed} } @failed;
        if ( !@failed ) {
            $parallel_safe = 0;
            $run->{jobs} = 1;
            _warn( $run, Test::Mutation::Message::warning('tests-conflict') );
        }
    }

    my ( %tests, %breakable );
    for my $test ( $tests->@* ) {
        my ( $result, $record ) = $outcome->{$test}->@{qw(result record)};
        my %files;
        for my $path ( $targets->@* ) {
            my $absolute = "$root/$path";
            $files{$path} = $record->{served}{$absolute} if $record->{served}{$absolute};
            my $lines = $record->{breakable}{$absolute};
            $breakable{$path} = { ( $breakable{$path} ? $breakable{$path}->%* : () ), $lines->%* } if $lines;
            _warn( $run, Test::Mutation::Message::warning( 'loaded-around-hook', test => $test, path => $path ) )
              if $record->{bypassed}{$absolute};
        }
        $tests{$test} = { duration => $result->{duration}, files => \%files, early => $result->{early} };
    }
    return {
        tests         => \%tests,
        breakable     => \%breakable,
        parallel_safe => $parallel_safe,
        failures      => [ map { _failure( $_, $outcome->{$_}{result} ) } @failed ],
    };
}

sub _mutants ( $run, $mutants, $baseline ) {
    my $config   = $run->{config};
    my $coverage = Test::Mutation::Coverage->new(
        mode      => $config->coverage,
        breakable => $baseline->{breakable},
        tests     => { map { $_ => { $baseline->{tests}{$_}->%{qw(duration files)} } } keys $baseline->{tests}->%* },
    );

    my $cache = $config->cache ? _open_cache( $run, $baseline ) : undef;

    # Each mutant has one entry under its identifier, so the result keeps the order of the analysis.
    my ( %entry_of, @jobs );
    for my $mutant ( $mutants->@* ) {
        if ( $mutant->suppressed ) {
            $entry_of{ $mutant->id } = _suppressed($mutant);
            next;
        }
        my $tests = $coverage->tests_for($mutant);
        my $job   = {
            mutant   => $mutant,
            tests    => $tests,
            index    => 0,
            verdict  => Test::Mutation::Verdict::start(),
            duration => 0
        };
        $entry_of{ $mutant->id } = _reused_entry( $run, $cache, $job ) if $cache && $tests->@*;
        push @jobs, $job if !$entry_of{ $mutant->id };
    }

    my @waiting = @jobs;
    my $finish  = sub ($job) {
        $entry_of{ $job->{mutant}->id } = _finish( $run, $job );
        _release( $run, $job );
        return;
    };
    my $measure = sub {
        return Test::Mutation::Pool::run(
            jobs => $run->{jobs},
            work => $run->{stats},
            next => sub {
                while ( my $job = shift @waiting ) {
                    my $task = $job->{tests}->@* ? _next_test( $run, $job, $baseline ) : _next_code( $run, $job );
                    return $task if $task;
                    $finish->($job);
                }
                return;
            },
            done => sub ( $task, $result ) {
                return _after_task( $run, $baseline, $task, $result ) || $finish->( $task->{payload}{job} );
            },
        );
    };

    # A signal ends the measurement, and the mutants that it measured keep their results.
    my $attempt   = Test::Mutation::Try::attempt( $measure, 'interruption' );
    my $completed = exists $attempt->{value};
    if ( !$completed ) {
        my $error = $attempt->{error};
        die $error if !$INTERRUPTION->check($error);    ## no critic (ErrorHandling::RequireCarping)
        $run->{interrupted} = $error->signal;
        for my $job ( grep { !$entry_of{ $_->{mutant}->id } } @jobs ) {
            my $tests_run = $job->{verdict}{tests};
            $tests_run += $job->{first}{tests} if $job->{first};
            $entry_of{ $job->{mutant}->id } =
              _entry( $job->{mutant}, 'Pending', 'interrupted', 'the run was interrupted',
                undef, $job->{tests}, $tests_run, $job->{duration} );
        }
    }

    my @entries = map { $entry_of{ $_->id } } $mutants->@*;
    my $changes = $completed && $run->{tree} ? Test::Mutation::Tree::changes( $run->{tree}, _tree($run) ) : [];
    _recheck( $run, [ sort keys $baseline->{tests}->%* ], \@entries, $changes ) if $changes->@*;
    _save_cache( $run, $cache, \@entries )                                      if $cache && !$changes->@*;
    _ignore_repeated_code( $run, \@entries );
    return \@entries;
}

sub _tree ($run) {
    return _walk( $run, $run->{root}, '.git', $run->{config}->cache_dir );
}

# A mutant runs with the rights of the tests, so it may leave a file that makes a test fail from then on.
# A kill by such a test proves nothing about the mutant, so the unmodified tests run once more to find them.
sub _recheck ( $run, $tests, $entries, $changes ) {
    my @named   = $changes->@[ 0 .. List::Util::min( $changes->$#*, $CHANGES_NAMED - 1 ) ];
    my $rest    = $changes->@* - @named;
    my $changed = join( ', ', @named ) . ( $rest ? " and $rest more" : q{} );
    _warn( $run, Test::Mutation::Message::warning( 'project-changed', changes => $changed ) );

    my $outcome = _unmodified( $run, 'recheck', 0, $run->{jobs}, $tests, 'verifications' );
    my %broken  = map { $_ => 1 } grep { !$outcome->{$_}{result}{passed} } $tests->@*;
    for my $entry ( grep { $_->{status} eq 'Killed' && $broken{ $_->{by} } } $entries->@* ) {
        $entry->@{qw(status reason detail)} =
          ( 'NoVerdict', 'project-changed', "$entry->{by} fails without a mutant since the project changed" );
    }
    _warn( $run, Test::Mutation::Message::warning( 'test-unstable', test => $_ ) ) for sort keys %broken;
    return;
}

sub _after_task ( $run, $baseline, $task, $result ) {
    my $job  = $task->{payload}{job};
    my $kind = $task->{payload}{kind};
    my $check =
        $kind eq 'test'      ? _after_test( $run, $task, $result )
      : $kind =~ /\Asyntax-/ ? _after_syntax( $run, $task, $result )
      :                        _after_code( $run, $task, $result );
    return $check if $check;

    if ( $kind !~ /\Acode-/ ) {
        $job->{verdict} = Test::Mutation::Verdict::step( $job->{verdict}, $job->{outcome} );
        $job->{index}++;
        return _next_test( $run, $job, $baseline )
          if !defined $job->{verdict}{status} && $job->{index} < $job->{tests}->@*;
        my $trial = Test::Mutation::Verdict::conclude( $job->{verdict} );
        if ( my $first = delete $job->{first} ) {
            $job->{verdict} = Test::Mutation::Verdict::confirm( $first, $trial );
        }
        elsif ( $run->{config}->mutant->@* && ( $trial->{status} eq 'Killed' || $trial->{status} eq 'Survived' ) ) {
            _release( $run, $job );
            delete $job->{spec};
            $job->{first}   = $trial;
            $job->{index}   = 0;
            $job->{verdict} = Test::Mutation::Verdict::start();
            return _next_test( $run, $job, $baseline );
        }
    }
    return _next_code( $run, $job );
}

sub _support_files ( $run, $tracked ) {
    my %tracked = map { $_ => 1 } $tracked->@*;
    my %directory;
    for my $path ( $tracked->@* ) {
        my ($top) = split m{/}, $path;
        $directory{$top} = 1 if $top ne $path;
    }
    my %found;
    for my $directory ( sort keys %directory ) {
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    my $relative = substr $File::Find::name, 1 + length $run->{root};
                    $found{$relative} = 1 if -f $File::Find::name && !$tracked{$relative};
                },
            },
            "$run->{root}/$directory",
        );
    }
    my @ordered = sort keys %found;
    return @ordered;
}

sub _open_cache ( $run, $baseline ) {
    my $config = $run->{config};
    my $root   = $run->{root};
    my $file   = join q{/}, $run->{project}, $config->cache_dir, 'cache.json';
    my %digest;
    my $digest_of = sub ($path) {
        $digest{$path} = Digest::SHA::sha256_hex( _slurp("$root/$path") ) if !defined $digest{$path};
        return $digest{$path};
    };
    my @tests       = sort keys $baseline->{tests}->%*;
    my @interpreter = map { defined ? $_ : q{} } ( stat $config->perl )[ 7, 9 ];
    my @shared      = (
        $VERSION,
        $config->perl,
        @interpreter,
        scalar $config->switch->@*,
        $config->switch->@*,
        $config->coverage,
        $config->equivalence,
        ( map { defined $ENV{$_} ? ( 'set', $ENV{$_} ) : ('unset') } qw(PERL_HASH_SEED PERL_PERTURB_KEYS) ),
        map { ( $_, $digest_of->($_) ) } _support_files( $run, [ @tests, keys $run->{sources}->%* ] ),
    );
    return {
        path    => $file,
        records => Test::Mutation::Cache::load($file),
        keys    => {},
        key_of  => sub ($job) {
            my $mutant = $job->{mutant};
            my @reach  = sort $job->{tests}->@*;
            my %loaded = map { $_ => 1 } $mutant->path, map { keys $baseline->{tests}{$_}{files}->%* } @reach;
            return Test::Mutation::Cache::key(
                @shared, $mutant->id, $mutant->replacement,
                ( map { ( 'test',   $_, $digest_of->($_) ) } @reach ),
                ( map { ( 'source', $_, $digest_of->($_) ) } sort keys %loaded ),
            );
        },
    };
}

sub _reused_entry ( $run, $cache, $job ) {
    my $mutant = $job->{mutant};
    my $key    = $cache->{keys}{ $mutant->id } = $cache->{key_of}->($job);
    return if $run->{config}->mutant->@*;
    my $record = $cache->{records}{ $mutant->id };
    return                                                  if !$record || $record->{inputs} ne $key;
    $run->{code_of_mutant}{ $mutant->id } = $record->{code} if defined $record->{code};
    $run->{reused}++;
    my $entry =
      _entry( $mutant, $record->@{qw(status reason detail by)}, $job->{tests}, $record->@{qw(tests_run duration)} );
    $run->{listener}->( 'mutant', $entry );
    return $entry;
}

sub _save_cache ( $run, $cache, $entries ) {
    my %records = $cache->{records}->%*;
    for my $entry ( $entries->@* ) {
        my $id  = $entry->{mutant}->id;
        my $key = $cache->{keys}{$id} or next;
        $records{$id} = {
            inputs => $key,
            $entry->%{qw(status reason detail by tests_run duration)}, code => $run->{code_of_mutant}{$id}
        };
    }
    Test::Mutation::Cache::save( $cache->{path}, \%records );
    return;
}

sub _ignore_repeated_code ( $run, $entries ) {
    my %first;
    for my $entry ( grep { $UNDETECTED{ $_->{status} } } $entries->@* ) {
        my $mutant = $entry->{mutant};
        my $code   = $run->{code_of_mutant}{ $mutant->id } or next;
        my $key    = join "\n", $mutant->path, $code;
        if ( defined $first{$key} ) {
            $entry->@{qw(status reason detail)} =
              ( 'Ignored', 'same-code-as-mutant', "compiles to the same code as mutant $first{$key}" );
            next;
        }
        $first{$key} = $mutant->id;
    }
    return;
}

sub _next_code ( $run, $job ) {
    return if !$run->{config}->equivalence || defined $job->{code} || !$job->{mutant}->comparable;
    return if !$UNDETECTED{ Test::Mutation::Verdict::final( $job->{verdict} ) };
    my $mutant = $job->{mutant};
    my $path   = $mutant->path;
    $job->@{qw(file spec)} = _write_mutant( $run, $run->{sources}{$path}, $mutant, _job_root( $run, $job ) )
      if !defined $job->{spec};

    # Two runs of the original show whether its compiled code has a stable text.
    my ( $once, $again ) = ( $run->{code_of_original}{$path} ||= [] )->@*;
    return _compile_task( $run, $job, 'code-original', "$run->{root}/$path", '-MO=Deparse' ) if !defined $again;
    if ( !length $once || $once ne $again ) {
        _warn( $run, Test::Mutation::Message::warning( 'decompiled-code-unstable', path => $path ) );
        return;
    }
    return _compile_task( $run, $job, 'code-mutant', $job->{file}, '-MO=Deparse' );
}

sub _after_code ( $run, $task, $result ) {
    my $job    = $task->{payload}{job};
    my $usable = $result->{exit} == 0 && !$result->{timed_out} && length $result->{output};
    my $digest = $usable ? $result->{digest} : q{};
    if ( $task->{payload}{kind} eq 'code-original' ) {
        push $run->{code_of_original}{ $job->{mutant}->path }->@*, $digest;
        return;
    }
    $job->{code} = $digest;
    return;
}

sub _after_test ( $run, $task, $result ) {
    my $payload  = $task->{payload};
    my $job      = $payload->{job};
    my $path     = $job->{mutant}->path;
    my $absolute = _job_root( $run, $job ) . "/$path";
    my $record   = _collect($task);
    $job->{duration} += $result->{duration};
    $job->{outcome} = {
        test        => $payload->{test},
        result      => _ending($result),
        served      => $record->{served}{$absolute}                                         ? 1 : 0,
        load_failed => $record->{load_failed}{$absolute} || !$record->{compiled}{$absolute} ? 1 : 0,
        bypassed    => $record->{bypassed}{$absolute}                                       ? 1 : 0,
        syntax      => $job->{syntax},
    };
    return if !$job->{outcome}{served} || !$job->{outcome}{load_failed} || defined $job->{syntax};

    my $known = $run->{syntax_of_original}{$path};
    return _compile_task( $run, $job, 'syntax-original', "$run->{root}/$path", '-c' ) if !defined $known;
    return _compile_task( $run, $job, 'syntax-mutant',   $job->{file},         '-c' ) if $known;
    $job->{outcome}{syntax} = $job->{syntax} = 'standalone';
    return;
}

# A failed check of the original says that the source does not compile alone, so its mutants say nothing more.
sub _after_syntax ( $run, $task, $result ) {
    my $job      = $task->{payload}{job};
    my $path     = $job->{mutant}->path;
    my $ok       = $result->{exit} == 0 && !$result->{timed_out} ? 1 : 0;
    my $original = $task->{payload}{kind} eq 'syntax-original';
    if ($original) {
        $run->{syntax_of_original}{$path} = $ok;
        return _compile_task( $run, $job, 'syntax-mutant', $job->{file}, '-c' ) if $ok;
        _warn( $run, Test::Mutation::Message::warning( 'syntax-check-failed', path => $path ) );
    }
    $job->{outcome}{syntax} = $job->{syntax} = $ok ? 'ok' : $original ? 'standalone' : 'compile-phase';
    return;
}

sub _next_test ( $run, $job, $baseline ) {
    my $config = $run->{config};
    my $mutant = $job->{mutant};
    if ( !defined $job->{spec} ) {
        $job->@{qw(file spec)} =
          _write_mutant( $run, $run->{sources}{ $mutant->path }, $mutant, _job_root( $run, $job ) );
    }
    my $test     = $job->{tests}[ $job->{index} ];
    my $duration = $baseline->{tests}{$test}{duration} * $config->timeout_factor;
    return _test_task(
        $run,
        root            => _job_root( $run, $job ),
        test            => $test,
        spec            => $job->{spec},
        timeout         => List::Util::max( $duration, $config->timeout_floor ),
        stop_on_failure => $baseline->{tests}{$test}{early} ? 0 : 1,
        payload         => { kind => 'test', job => $job },
    );
}

sub _compile_task ( $run, $job, $kind, $file, $switch ) {
    my $config = $run->{config};
    my $root   = _job_root( $run, $job );
    $run->{stats}{compiles}++;
    return {
        command         => [ $config->perl, $config->switch->@*, $switch, $file ],
        env             => { PERL_HASH_SEED => '0', PERL_PERTURB_KEYS => '0', PWD => $root },
        cwd             => $root,
        timeout         => $config->baseline_timeout,
        output_limit    => $OUTPUT_LIMIT,
        stop_on_failure => 0,
        payload         => { kind => $kind, job => $job },
    };
}

# A failing test of the unmodified run, with the reason of the limit that ended it.
sub _failure ( $test, $result ) {
    my $reason = Test::Mutation::Verdict::limit( _ending($result) );
    return { test => $test, $result->%{qw(output errors)}, defined $reason ? ( reason => $reason ) : () };
}

# The outcome of a test: the limit of the pool that ended it, or its own verdict.
sub _ending ($result) {
    return 'timeout'  if $result->{timed_out};
    return 'overflow' if $result->{overflowed};
    return $result->{passed} ? 'pass' : 'fail';
}

sub _finish ( $run, $job ) {
    unlink grep { defined } $job->@{qw(file spec)};
    my $verdict = Test::Mutation::Verdict::conclude( $job->{verdict} );
    my $mutant  = $job->{mutant};
    my $code    = defined $job->{code} ? $job->{code} : q{};
    my ( $status, $reason, $detail ) = $verdict->@{qw(status reason detail)};
    if ( length $code ) {
        $run->{code_of_mutant}{ $mutant->id } = $code;
        ( $status, $reason, $detail ) =
          ( 'Ignored', 'same-code-as-original', 'compiles to the same code as the original' )
          if $code eq $run->{code_of_original}{ $mutant->path }[0];
    }
    my $entry =
      _entry( $mutant, $status, $reason, $detail, $verdict->{by}, $job->{tests}, $verdict->{tests}, $job->{duration} );
    $run->{listener}->( 'mutant', $entry );
    return $entry;
}

1;

__END__

=head1 NAME

Test::Mutation::Runner - run the tests against every mutant

=head1 SYNOPSIS

    my $result = Test::Mutation::Runner::run( $config, sub ( $event, $data ) { } );

=head1 DESCRIPTION

The runner finds the source and test files, generates the mutants, and measures each one.
It first runs every test against the unmodified sources through the same hook that later serves the mutants.
That run proves the hook leaves the tests passing, times each test, and records which test reaches which line.
The runner serves each mutant to its covering tests in project-relative path order until a test decides its verdict.
When a run names mutant identifiers, it bypasses cached verdicts and repeats the covering tests for each candidate C<Killed> or C<Survived> in the same order.
In copy mode both attempts start from the tree that the unmodified tests left.
Conflicting observations give C<NoVerdict> and the result names both observations.
It writes temporary files under the work directory and leaves the project files unchanged.
The tests run in copies of the project: the unmodified run in one copy, and each job in a copy of the result.
After every mutant, the runner restores a copy that the tests changed.

=head1 FUNCTIONS

=head2 analyze

Returns the sources, the mutants, and the files that could not be analyzed, without running a test.
The C<left_out> key maps a file to the number of its places that the analysis left out, and a run warns about each such file.
The C<rejected> key holds every change that the generator refused, with the file, the mutator, the line, and the rule.
The C<inventory> key holds the count and the digest of the mutants before C<shard> takes its part.
A suppression comment that L<Test::Mutation::Suppression> refuses, in any analyzed file, ends the analysis with one usage error that lists every refusal.
The mutants of every mutator decide whether a comment suppresses one, so the choice of mutators changes no refusal.

=head2 run

Runs the measurement and returns a L<Test::Mutation::Result>.
The listener receives C<analyzed>, C<baseline>, and C<mutant> events with a hash reference of details.

=head2 run_command

    my $status = Test::Mutation::Runner::run_command( $config, $source, $mutant, [ 'prove', '-l', 't/a.t' ] );

Runs a command with one mutant active and returns its exit status.
The mutant reaches every Perl process the command starts through C<PERL5OPT>, so a process in taint mode runs the original code.

=head2 target_pairs

    my $pairs = Test::Mutation::Runner::target_pairs( $root, \@paths, $mutated_path, $mutant_file );

Returns the targets of a mutant run as pairs of an original file and the file to serve in its place.
Every source file goes through the hook, so a mutant run differs from the unmodified run in the text of one file alone.

=head2 shim_text

Returns the source of L<Test::Mutation::Shim> renamed for a generation.
A run inside another run uses the next generation, so both shims work in one process.

=cut
