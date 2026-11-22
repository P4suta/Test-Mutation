package Permutl::Runner;
use v5.36;
use Cwd             ();
use File::Path      ();
use File::Temp      ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef CodeRef Dict HashRef InstanceOf Int Str Tuple);
use Type::Params    qw(signature_for);
use Permutl::Coverage;
use Permutl::Diff;
use Permutl::Git;
use Permutl::Mutant::Generator;
use Permutl::Mutator::Catalog;
use Permutl::Pool;
use Permutl::Project;
use Permutl::Record;
use Permutl::Result;
use Permutl::Source;
use Permutl::Syntax::PPI;
use Permutl::Verdict;

our $VERSION = '0.001';

my $SHIM_FILE = 'Permutl/Shim.pm';

my $ANALYSIS = Dict [
    sources  => HashRef [ InstanceOf ['Permutl::Source'] ],
    mutants  => ArrayRef [ InstanceOf ['Permutl::Mutant'] ],
    problems => ArrayRef [ Dict [ path => Str, problem => Str ] ],
];

signature_for analyze => ( positional => [ InstanceOf ['Permutl::Config'] ], returns => $ANALYSIS );

sub analyze ($config) {
    my $root     = Cwd::abs_path( $config->root );
    my $mutators = Permutl::Mutator::Catalog::choose(
        profile => $config->profile,
        enable  => $config->enable,
        disable => $config->disable,
    );
    my ( %sources, @mutants, @problems );
    my %only    = map { $_ => 1 } $config->only->@*;
    my $changed = defined $config->since ? Permutl::Git::changed( $root, $config->since ) : undef;
    for my $path ( Permutl::Project::files( $root, $config->source_include, $config->source_exclude )->@* ) {
        next if $changed && !$changed->{$path};
        my $source   = Permutl::Source->from_bytes( path => $path, bytes => _slurp("$root/$path") );
        my $analysis = Permutl::Syntax::PPI::analyze($source);
        if ( defined $analysis->{problem} ) {
            push @problems, { path => $path, problem => $analysis->{problem} };
            next;
        }
        $sources{$path} = $source;
        my $generated =
          Permutl::Mutant::Generator::generate( source => $source, analysis => $analysis, mutators => $mutators );
        push @mutants, grep { !$changed || _in_changed_lines( $changed->{$path}, $_ ) }
          grep { !%only || $only{ $_->id } } $generated->@*;
    }
    return { sources => \%sources, mutants => \@mutants, problems => \@problems };
}

sub _in_changed_lines ( $ranges, $mutant ) {
    my ( $first, $last ) = ( $mutant->from->[0], $mutant->to->[0] );
    $last-- if $last > $first && $mutant->to->[1] == 1;
    return Permutl::Diff::touches( $ranges, $first, $last );
}

signature_for run => (
    positional => [ InstanceOf ['Permutl::Config'], CodeRef ],
    returns    => InstanceOf ['Permutl::Result'],
);

sub run ( $config, $listener ) {
    my $started  = Time::HiRes::time();
    my $root     = Cwd::abs_path( $config->root );
    my $analysis = analyze($config);
    my @tests    = Permutl::Project::files( $root, $config->test_include, $config->test_exclude )->@*;
    my @active   = grep { !$_->suppressed } $analysis->{mutants}->@*;
    my %targets  = map  { $_->path => 1 } @active;

    my $run = {
        config   => $config,
        root     => $root,
        listener => $listener,
        sources  => $analysis->{sources},
        jobs     => $config->jobs,
        sequence => 0,
        taint    => {},
        warnings => [],
    };
    $listener->( 'analyzed',
        { mutants => scalar(@active), files => scalar( keys %targets ), tests => scalar(@tests) } );

    my %result = (
        root              => $root,
        sources           => { map { $_ => $analysis->{sources}{$_}->text } keys $analysis->{sources}->%* },
        tests             => [],
        entries           => [],
        problems          => $analysis->{problems},
        warnings          => $run->{warnings},
        baseline_failures => [],
        parallel_safe     => 1,
        started           => $started,
    );

    if ( @active && @tests ) {
        _prepare_work($run);
        my $measured = eval {
            $run->{targets} = [ sort keys %targets ];
            my $baseline = _baseline( $run, \@tests, $run->{targets} );
            $result{parallel_safe}     = $baseline->{parallel_safe};
            $result{baseline_failures} = $baseline->{failures};
            $result{tests} =
              [ map { { name => $_, duration => $baseline->{tests}{$_}{duration} } } sort keys $baseline->{tests}->%* ];
            if ( !$baseline->{failures}->@* ) {
                $listener->( 'baseline', { tests => scalar(@tests), jobs => $run->{jobs} } );
                $result{entries} = _mutants( $run, $analysis->{mutants}, $baseline );
            }
            1;
        };
        my $error = $@;
        File::Path::remove_tree( $run->{work} ) if !$config->keep_work;
        die $error                              if !$measured;            ## no critic (ErrorHandling::RequireCarping)
    }
    else {
        push $run->{warnings}->@*, 'no test files match' if @active && !@tests;
        $result{entries} = [ map { _entry( $_, $_->suppressed ? 'Ignored' : 'NoCoverage', undef, undef, [], 0, 0 ) }
              $analysis->{mutants}->@* ];
    }

    return Permutl::Result->new( %result, jobs => $run->{jobs}, finished => Time::HiRes::time() );
}

sub _slurp ($path) {
    open my $handle, '<:raw', $path or die "cannot read $path: $!\n";
    local $/ = undef;
    my $content = readline $handle;
    close $handle or die "cannot close $path: $!\n";
    return $content // q{};
}

sub _spew ( $path, $content ) {
    open my $handle, '>:raw', $path or die "cannot write $path: $!\n";
    print {$handle} $content or die "cannot write $path: $!\n";
    close $handle            or die "cannot close $path: $!\n";
    return;
}

sub _entry ( $mutant, $status, $reason, $by, $covered_by, $tests_run, $duration ) {
    return {
        mutant     => $mutant,
        status     => $status,
        reason     => $reason,
        by         => $by,
        covered_by => $covered_by,
        tests_run  => $tests_run,
        duration   => $duration,
    };
}

sub _prepare_work ($run) {
    my $base = $run->{root} . q{/} . $run->{config}->work_directory;
    File::Path::make_path($base);
    my $work       = File::Temp::tempdir( 'run-XXXXXX', DIR => $base );
    my $outer      = $ENV{PERMUTL_GENERATION};
    my $generation = defined $outer ? $outer + 1 : 1;
    File::Path::make_path( map { "$work/$_" } 'shim/Permutl/Shim', 'mutants', 'records', 'tmp', 'stderr' );
    _spew( "$work/shim/Permutl/Shim/G$generation.pm", shim_text($generation) );
    $run->{work}       = $work;
    $run->{generation} = $generation;
    $run->{package}    = "Permutl::Shim::G$generation";
    return;
}

signature_for shim_text => ( positional => [Str], returns => Str );

sub shim_text ($generation) {
    my $text    = _module_text($SHIM_FILE);
    my $renamed = $text =~ s/^package Permutl::Shim;$/package Permutl::Shim::G$generation;/m;
    my $marked  = $text =~ s/^my \$GENERATION = 0;$/my \$GENERATION = $generation;/m;
    die "cannot prepare the shim for generation $generation\n" if !$renamed || !$marked;
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
    die "cannot find $file\n";
}

sub _taint_switch ( $run, $test ) {
    if ( !exists $run->{taint}{$test} ) {
        open my $handle, '<', "$run->{root}/$test" or die "cannot read $test: $!\n";
        my $first = readline $handle;
        close $handle or die "cannot close $test: $!\n";
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

sub _environment ( $run, $spec ) {
    my $generation = $run->{generation};
    return (
        "PERMUTL_SPEC_G$generation" => $spec,
        PERMUTL_GENERATION          => $generation,
        PERL5OPT                    => join( q{ }, _inherited('PERL5OPT'), '-M' . $run->{package} ),
        PERL5LIB                    => join( q{:}, "$run->{work}/shim",    _inherited('PERL5LIB') ),
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

sub _write_mutant ( $run, $source, $mutant ) {
    my $file = "$run->{work}/mutants/" . $mutant->id . '.pm';
    _spew( $file, $source->to_bytes( $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement ) ) );
    my $targets = target_pairs( $run->{root}, $run->{targets} ? $run->{targets} : [], $mutant->path, $file );
    my $spec    = _spec( $run, 'mutants/' . $mutant->id, 0, $targets );
    return ( $file, $spec );
}

signature_for run_command => (
    positional => [
        InstanceOf ['Permutl::Config'], InstanceOf ['Permutl::Source'], InstanceOf ['Permutl::Mutant'], ArrayRef [Str]
    ],
    returns => Int,
);

sub run_command ( $config, $source, $mutant, $command ) {
    my $run = { config => $config, root => Cwd::abs_path( $config->root ) };
    _prepare_work($run);
    my ( undef, $spec ) = _write_mutant( $run, $source, $mutant );
    my $status = do {
        local %ENV = ( %ENV, _environment( $run, $spec ) );
        system { $command->[0] } $command->@*;
    };
    File::Path::remove_tree( $run->{work} );
    return 127                     if $status == -1;
    return 128 + ( $status & 127 ) if $status & 127;
    return $status >> 8;
}

sub _test_task ( $run, %arg ) {
    my $sequence   = ++$run->{sequence};
    my $work       = $run->{work};
    my $generation = $run->{generation};
    my $record     = "$work/records/$sequence";
    my $tmp        = "$work/tmp/$sequence";
    File::Path::make_path( $record, $tmp );
    my $taint = _taint_switch( $run, $arg{test} );
    my $load  = '-M' . $run->{package};
    return {
        command => [
            $run->{config}->perl,     $run->{config}->switches->@*,
            ( $taint ? $taint : () ), "-I$work/shim",
            $load,                    $arg{test},
        ],
        env => {
            _environment( $run, $arg{spec} ),
            "PERMUTL_RECORD_G$generation" => $record,
            HARNESS_ACTIVE                => 1,
            TMPDIR                        => $tmp,
        },
        cwd             => $run->{root},
        timeout         => $arg{timeout},
        stop_on_failure => $arg{stop_on_failure},
        stderr          => "$work/stderr/$sequence.txt",
        payload         => { $arg{payload}->%*, test => $arg{test}, record => $record, tmp => $tmp },
    };
}

sub _collect ($task) {
    my $payload = $task->{payload};
    my $record  = Permutl::Record::read_directory( $payload->{record} );
    my $errors  = -f $task->{stderr} ? _slurp( $task->{stderr} ) : q{};
    File::Path::remove_tree( $payload->{record}, $payload->{tmp} );
    unlink $task->{stderr};
    return ( $record, $errors );
}

sub _baseline ( $run, $tests, $targets ) {
    my $root = $run->{root};
    my $spec = _spec( $run, 'baseline', $run->{config}->coverage eq 'line',
        [ map { [ "$root/$_", "$root/$_" ] } $targets->@* ] );
    my $pass = sub ( $jobs, $names ) {
        my @queue = $names->@*;
        my %outcome;
        Permutl::Pool::run(
            jobs => $jobs,
            next => sub {
                my $test = shift @queue or return;
                return _test_task(
                    $run,
                    test            => $test,
                    spec            => $spec,
                    timeout         => $run->{config}->baseline_timeout,
                    stop_on_failure => 0,
                    payload         => {},
                );
            },
            done => sub ( $task, $result ) {
                my ( $record, $errors ) = _collect($task);
                $outcome{ $task->{payload}{test} } = { result => $result, record => $record, errors => $errors };
                return;
            },
        );
        return \%outcome;
    };

    my $outcome       = $pass->( $run->{jobs}, $tests );
    my @failed        = grep { !$outcome->{$_}{result}{passed} } $tests->@*;
    my $parallel_safe = 1;
    if ( @failed && $run->{jobs} > 1 ) {
        my $serial = $pass->( 1, \@failed );
        $outcome->{$_} = $serial->{$_} for @failed;
        @failed = grep { !$outcome->{$_}{result}{passed} } @failed;
        if ( !@failed ) {
            $parallel_safe = 0;
            $run->{jobs} = 1;
            push $run->{warnings}->@*,
              'the tests fail when they run side by side, so the mutants run one test at a time';
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
            push $run->{warnings}->@*, "$test loads $path around the hook and cannot detect its mutants"
              if $record->{bypassed}{$absolute};
        }
        $tests{$test} = { duration => $result->{duration}, files => \%files, early => $result->{early} };
    }
    return {
        tests         => \%tests,
        breakable     => \%breakable,
        parallel_safe => $parallel_safe,
        failures      => [
            map { { test => $_, output => $outcome->{$_}{result}{output}, errors => $outcome->{$_}{errors} } } @failed
        ],
    };
}

sub _mutants ( $run, $mutants, $baseline ) {
    my $config   = $run->{config};
    my $coverage = Permutl::Coverage->new(
        mode      => $config->coverage,
        breakable => $baseline->{breakable},
        tests     => { map { $_ => { $baseline->{tests}{$_}->%{qw(duration files)} } } keys $baseline->{tests}->%* },
    );

    my ( @entries, @jobs );
    for my $mutant ( $mutants->@* ) {
        if ( $mutant->suppressed ) {
            push @entries, _entry( $mutant, 'Ignored', 'suppressed by a comment', undef, [], 0, 0 );
            next;
        }
        my $tests = $coverage->tests_for($mutant);
        my $job =
          { mutant => $mutant, tests => $tests, index => 0, verdict => Permutl::Verdict::start(), duration => 0 };
        if ( $tests->@* ) {
            push @jobs, $job;
        }
        else {
            push @entries, _finish( $run, $job );
        }
    }

    $run->{syntax_of_original} = {};
    Permutl::Pool::run(
        jobs => $run->{jobs},
        next => sub {
            my $job = shift @jobs or return;
            return _next_test( $run, $job, $baseline );
        },
        done => sub ( $task, $result ) {
            my $job = $task->{payload}{job};
            my $check =
              $task->{payload}{kind} eq 'test'
              ? _after_test( $run, $task, $result )
              : _after_syntax( $run, $task, $result );
            return $check if $check;

            $job->{verdict} = Permutl::Verdict::step( $job->{verdict}, $job->{outcome} );
            $job->{index}++;
            if ( defined $job->{verdict}{status} || $job->{index} >= $job->{tests}->@* ) {
                push @entries, _finish( $run, $job );
                return;
            }
            return _next_test( $run, $job, $baseline );
        },
    );

    my %order = map { $mutants->[$_]->id => $_ } 0 .. $mutants->$#*;
    return [ sort { $order{ $a->{mutant}->id } <=> $order{ $b->{mutant}->id } } @entries ];
}

sub _after_test ( $run, $task, $result ) {
    my $payload  = $task->{payload};
    my $job      = $payload->{job};
    my $path     = $job->{mutant}->path;
    my $absolute = "$run->{root}/$path";
    my ($record) = _collect($task);
    $job->{duration} += $result->{duration};
    $job->{outcome} = {
        test        => $payload->{test},
        result      => $result->{timed_out} ? 'timeout' : $result->{passed} ? 'pass' : 'fail',
        served      => $record->{served}{$absolute}                                         ? 1 : 0,
        load_failed => $record->{load_failed}{$absolute} || !$record->{compiled}{$absolute} ? 1 : 0,
        bypassed    => $record->{bypassed}{$absolute}                                       ? 1 : 0,
        syntax_ok   => $job->{syntax_ok},
    };
    return if !$job->{outcome}{served} || !$job->{outcome}{load_failed} || defined $job->{syntax_ok};

    my $known = $run->{syntax_of_original};
    return _syntax_task( $run, $job, 'syntax-original', $absolute )    if !exists $known->{$path};
    return _syntax_task( $run, $job, 'syntax-mutant',   $job->{file} ) if $known->{$path};
    $job->{outcome}{syntax_ok} = $job->{syntax_ok} = 0;
    return;
}

sub _after_syntax ( $run, $task, $result ) {
    my $job  = $task->{payload}{job};
    my $path = $job->{mutant}->path;
    my $ok   = $result->{exit} == 0 && !$result->{timed_out} ? 1 : 0;
    unlink $task->{stderr};
    if ( $task->{payload}{kind} eq 'syntax-original' ) {
        $run->{syntax_of_original}{$path} = $ok;
        return _syntax_task( $run, $job, 'syntax-mutant', $job->{file} ) if $ok;
        push $run->{warnings}->@*,
          "$path does not pass a standalone syntax check, so its load failures count as compile errors";
    }
    $job->{outcome}{syntax_ok} = $job->{syntax_ok} = $ok;
    return;
}

sub _next_test ( $run, $job, $baseline ) {
    my $config = $run->{config};
    my $mutant = $job->{mutant};
    if ( !defined $job->{spec} ) {
        $job->@{qw(file spec)} = _write_mutant( $run, $run->{sources}{ $mutant->path }, $mutant );
    }
    my $test     = $job->{tests}[ $job->{index} ];
    my $duration = $baseline->{tests}{$test}{duration} * $config->timeout_factor;
    return _test_task(
        $run,
        test            => $test,
        spec            => $job->{spec},
        timeout         => $duration > $config->timeout_floor ? $duration : $config->timeout_floor,
        stop_on_failure => $baseline->{tests}{$test}{early}   ? 0         : 1,
        payload         => { kind => 'test', job => $job },
    );
}

sub _syntax_task ( $run, $job, $kind, $file ) {
    my $sequence = ++$run->{sequence};
    my $config   = $run->{config};
    return {
        command         => [ $config->perl, $config->switches->@*, '-c', $file ],
        env             => {},
        cwd             => $run->{root},
        timeout         => $config->baseline_timeout,
        stop_on_failure => 0,
        stderr          => "$run->{work}/stderr/$sequence.txt",
        payload         => { kind => $kind, job => $job },
    };
}

sub _finish ( $run, $job ) {
    unlink grep { defined } $job->@{qw(file spec)};
    my $verdict = $job->{verdict};
    my $entry   = _entry( $job->{mutant}, Permutl::Verdict::final($verdict),
        $verdict->{reason}, $verdict->{by}, $job->{tests}, $verdict->{tests}, $job->{duration}, );
    $run->{listener}->( 'mutant', $entry );
    return $entry;
}

1;

__END__

=head1 NAME

Permutl::Runner - run the tests against every mutant

=head1 SYNOPSIS

    my $result = Permutl::Runner::run( $config, sub ( $event, $data ) { } );

=head1 DESCRIPTION

The runner finds the source and test files, generates the mutants, and measures each one.
It first runs every test against the unmodified sources through the same hook that later serves the mutants.
That run proves the hook leaves the tests passing, times each test, and records which test reaches which line.
The runner then serves one mutant at a time to the tests that reach it, fastest first, until a test fails.
It writes temporary files under the work directory and leaves the project files unchanged.

=head1 FUNCTIONS

=head2 analyze

Returns the sources, the mutants, and the files that could not be analyzed, without running a test.

=head2 run

Runs the measurement and returns a L<Permutl::Result>.
The listener receives C<analyzed>, C<baseline>, and C<mutant> events with a hash reference of details.

=head2 run_command

    my $status = Permutl::Runner::run_command( $config, $source, $mutant, [ 'prove', '-l', 't/a.t' ] );

Runs a command with one mutant active and returns its exit status.
The mutant reaches every Perl process the command starts through C<PERL5OPT>, so a process in taint mode runs the original code.

=head2 target_pairs

    my $pairs = Permutl::Runner::target_pairs( $root, \@paths, $mutated_path, $mutant_file );

Returns the targets of a mutant run as pairs of an original file and the file to serve in its place.
Every source file goes through the hook, so a mutant run differs from the unmodified run in the text of one file alone.

=head2 shim_text

Returns the source of L<Permutl::Shim> renamed for a generation.
A run inside another run uses the next generation, so both shims work in one process.

=cut
