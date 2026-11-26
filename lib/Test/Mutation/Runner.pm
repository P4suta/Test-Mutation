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
use Test::Mutation::Error;
use Test::Mutation::Event;
use Test::Mutation::Message;
use Test::Mutation::Launch;
use Test::Mutation::Pool;
use Test::Mutation::Record;
use Test::Mutation::Evidence;
use Test::Mutation::Result;
use Test::Mutation::Signals;
use Test::Mutation::Select;
use Test::Mutation::Source;
use Test::Mutation::Status;
use Test::Mutation::Tree;
use Test::Mutation::Types qw(PathSelection);
use Test::Mutation::Try;
use Test::Mutation::Verdict;
use Test::Mutation::Witness;
use Test::Mutation::Syntax::PPI;
use Test::Mutation::Workspace;
use Test::Mutation::Workspace::Slot;
use Test::Mutation::Workspace::Processes;

our $VERSION = '0.001';

my $SHIM_FILE     = 'Test/Mutation/Shim.pm';
my %UNDETECTED    = map { $_->name => 1 } grep { $_->role eq 'undetected' } Test::Mutation::Status::rows()->@*;
my $CHANGES_NAMED = 5;
my $TYPED         = InstanceOf ['Test::Mutation::Error'];
my $INTERRUPTION  = InstanceOf ['Test::Mutation::Interrupted'];

# A test that prints a quarter of a gigabyte prints without end, as a loop that warns does, and the pool ends it.
# The bytes stay in no file, and a test that prints a hundred megabytes and then fails still fails on its own.
my $OUTPUT_LIMIT = 268_435_456;

signature_for phases => ( positional => [], returns => ArrayRef [Str] );

sub phases () {
    return Test::Mutation::Event::phases();
}

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
    my $selected = Test::Mutation::Select::resolve( config => $config, paths => $paths );
    return {
        sources   => $selected->sources,
        mutants   => $selected->mutants,
        problems  => $selected->unanalyzed,
        rejected  => $selected->rejected,
        left_out  => $selected->left_out,
        inventory => $selected->inventory,
    };
}

signature_for run => (
    positional => [
        InstanceOf ['Test::Mutation::Config'],
        CodeRef,
        Dict [
            paths         => Optional [ Maybe [PathSelection] ],
            selection     => Optional [ InstanceOf ['Test::Mutation::Selection'] ],
            baseline_only => Optional [Bool],
            reports       => Optional [Bool],
            summary       => Optional [ Maybe [Str] ]
        ],
        { default => sub { {} } }
    ],
    returns => InstanceOf ['Test::Mutation::Result'],
);

sub run ( $config, $listener, $options = {} ) {
    my $started = Time::HiRes::time();
    Test::Mutation::Event::phase( $listener, 'resolve' );
    my $project = Cwd::abs_path( $config->root );
    my $run     = {
        config   => $config,
        options  => $options,
        project  => $project,
        root     => $project,
        listener => $listener,
        jobs     => $config->jobs,
        sequence => 0,
        first    => {},
        warnings => {},
        free     => {},
        stats    => { map { $_ => 0 } qw(copies walks compiles spawns listings baseline_tests verifications) },
    };
    my $release = sub {
        Test::Mutation::Try::with_cleanup(
            sub { return [ Test::Mutation::Event::phase( $listener, 'release' ) ] },
            sub { _release_workspace($run) },
        );
        return;
    };
    my $result = Test::Mutation::Signals::watch(
        sub {
            Test::Mutation::Try::with_cleanup( sub { _measure( $run, $started ) }, $release );
        }
    );
    return Test::Mutation::Result->new(
        $result->%*,
        warnings => [ sort keys $run->{warnings}->%* ],
        finished => Time::HiRes::time()
    );
}

# The tests run in a copy of the project, so a file that a test writes or removes leaves the project as it was.
sub _copy_project ($run) {
    my $config  = $run->{config};
    my $project = $run->{project};
    $run->{name} = File::Basename::basename($project);

    my $directory = $run->{workspace}->directory;
    $run->{copies} = "$directory/slot";
    my @skip   = ( q{.git}, map { _inside( $project, $_ ) } $config->cache_dir, $config->report_dir );
    my $copied = Test::Mutation::Try::attempt(
        sub { $run->{root} = _new_copy( $run, "$directory/tree", $project, \@skip, $config->link ) } );
    return if exists $copied->{value};

    # A failure of the system names its path, and the run adds what the user can do about it.
    my $error = $copied->{error};
    die $error if !$TYPED->check($error);    ## no critic (ErrorHandling::RequireCarping)
    return Test::Mutation::Error::raise( 'project-uncopyable', reason => $error->message );
}

sub _prepare_project ( $run, $selection ) {
    unless ( $run->{config}->in_place ) {
        _copy_project($run);
        $selection->verify_copy( $run->{root} );
        return;
    }
    _warn( $run, Test::Mutation::Message::warning('in-place-observation') );
    my $root     = $run->{project};
    my $backup   = $run->{workspace}->directory . '/tree/original';
    my $original = _tree($run);
    my @skip     = ( '.git', map { _inside( $root, $_ ) } $run->{config}->cache_dir, $run->{config}->report_dir );
    my @opaque   = grep { !-l "$root/$_" && ( !-r _ || !( -f _ || -d _ && -x _ ) ) } keys $original->%*;
    Test::Mutation::Tree::copy( from => $root, to => $backup, skip => [ @skip, @opaque ], link => [] );
    $run->{stats}{copies}++;
    $run->{guard} = { backup => $backup, state => $original, opaque => \@opaque };
    return;
}

# The path from the project to a place inside it, and nothing for a place outside.
sub _inside ( $project, $path ) {
    my $absolute = File::Spec->canonpath( File::Spec->rel2abs( $path, $project ) );
    my $prefix   = "$project/";
    return substr( $absolute, 0, length $prefix ) eq $prefix ? substr $absolute, length $prefix : ();
}

# Each copy has the name of the project inside a directory of its own.
sub _new_copy ( $run, $directory, $from, $skip, $link, $state = undef ) {
    my $to = "$directory/$run->{name}";
    Test::Mutation::Tree::copy(
        from => $from,
        to   => $to,
        skip => $skip,
        link => $link,
        $state ? ( state => $state ) : ()
    );
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
    return $run->{root}       if !defined $run->{copies};
    return $job->{copy}{root} if $job->{copy};
    my $reference = $job->{starting_tree} || $run->{root};
    my $available = $run->{free}{$reference} ||= [];
    my $copy      = shift $available->@*;
    if ( !$copy ) {
        my $state = {};
        my $root  = _new_copy( $run, "$run->{copies}/" . ++$run->{slots}, $reference, [], [], $state );
        $copy = { root => $root, reference => $reference, state => $state };
    }
    $job->{copy} = $copy;
    return $copy->{root};
}

# A mutant may leave a changed copy behind, so the copy returns to its state before the next job takes it.
# A copy that fails to return stays out of use, and the next job makes a new one.
sub _release ( $run, $job ) {
    if ( $run->{guard} && delete $job->{used_project} ) {
        my $guard   = $run->{guard};
        my $changes = Test::Mutation::Tree::changes( $guard->{state}, _tree($run) );
        _restore_changes( $run, $guard, $changes );
        if ( $changes->@* && !$run->{setup_tests} ) {
            _changed_paths( $run, $changes );
            _confirm_after_restore( $run, $job, $guard );
        }
        return;
    }
    my $copy    = delete $job->{copy} or return;
    my $root    = $copy->{root};
    my $changes = Test::Mutation::Tree::changes( $copy->{state}, _walk( $run, $root ) );
    my $restore = sub {
        Test::Mutation::Tree::restore(
            from    => $copy->{reference},
            to      => $root,
            changes => $changes,
            state   => $copy->{state}
        );
    };
    if ( $changes->@* ) {
        my $restored = Test::Mutation::Try::attempt($restore);
        if ( exists $restored->{error} ) {
            $job->{restore_error} = "$restored->{error}";
            return;
        }
    }
    push $run->{free}{ $copy->{reference} }->@*, $copy;
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
    Test::Mutation::Event::phase( $listener, 'analyze' );
    my $selection =
      $run->{options}{selection} || Test::Mutation::Select::resolve( config => $config, $run->{options}->%* );
    Test::Mutation::Event::phase( $listener, 'plan' );
    my @tests   = $selection->tests->@*;
    my @active  = grep { !$_->suppressed } $selection->mutants->@*;
    my %targets = map  { $_->path => 1 } @active;
    $run->{sources} = $selection->sources;
    $run->{perl}    = $selection->perl;

    for my $path ( sort keys $selection->left_out->%* ) {
        my $count = $selection->left_out->{$path};
        _warn( $run,
            $count == 1
            ? Test::Mutation::Message::warning( 'analysis-left-out-place',  path => $path )
            : Test::Mutation::Message::warning( 'analysis-left-out-places', path => $path, count => $count ) );
    }
    $listener->( 'analyzed',
        { mutants => scalar(@active), files => scalar( keys %targets ), tests => scalar(@tests) } );

    my %result = (
        root              => $run->{project},
        sources           => { map { $_ => $selection->sources->{$_}->text } keys $selection->sources->%* },
        tests             => [],
        entries           => [],
        problems          => $selection->unanalyzed,
        baseline_failures => [],
        parallel_safe     => 1,
        shard             => $config->shard,
        inventory         => $selection->inventory,
        started           => $started,
    );

    if ( ( @active || $run->{options}{baseline_only} ) && @tests ) {
        Test::Mutation::Event::phase( $listener, 'acquire' );
        $run->{workspace} = Test::Mutation::Workspace::acquire( $run->{project} );
        Test::Mutation::Event::phase( $listener, 'build' );
        _prepare_project( $run, $selection );
        my $measure = sub {
            _prepare_work($run);
            $run->{targets} = [ sort keys $selection->sources->%* ];
            Test::Mutation::Event::phase( $listener, 'baseline' );
            _prepare_witnesses($run) if defined $run->{copies};
            my $baseline = _observed_baseline( $run, \@tests );
            my %measured = (
                parallel_safe     => $baseline->{parallel_safe},
                baseline_failures => $baseline->{failures},
                tests             => [
                    map { { name => $_, duration => $baseline->{tests}{$_}{duration} } }
                    sort keys $baseline->{tests}->%*
                ],
            );
            if ( !$baseline->{failures}->@* ) {
                _begin_in_place( $run, $baseline ) if $run->{guard} && !$run->{options}{baseline_only};
                $listener->( 'baseline', { tests => scalar(@tests), jobs => $run->{jobs} } );
                if ( !$run->{options}{baseline_only} ) {
                    Test::Mutation::Event::phase( $listener, 'mutants' );
                    $measured{entries} = _mutants( $run, $selection->mutants, $baseline );
                }
            }
            return \%measured;
        };
        %result = ( %result, $measure->()->%* );
    }
    else {
        _warn( $run, Test::Mutation::Message::warning('tests-unmatched') )
          if ( @active || $run->{options}{baseline_only} ) && !@tests;
        $result{entries} =
          [ map { $_->suppressed ? _suppressed($_) : _entry( $_, 'NoCoverage', 'unreached', undef, undef, [], 0, 0 ) }
              $selection->mutants->@* ];
    }

    Test::Mutation::Event::phase( $listener, 'conclude' );
    return {
        %result,
        jobs        => $run->{jobs},
        interrupted => $run->{interrupted},
        reused      => $run->{reused} || 0,
        in_copies   => $config->in_place ? 0 : 1,
        stats       => $run->{stats},
    };
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

sub _release_workspace ($run) {
    my $workspace = delete $run->{workspace} or return;
    if ( my $guard = delete $run->{guard} ) {
        my $restored = Test::Mutation::Try::attempt( sub { _restore_project( $run, $workspace, $guard ) } );
        if ( exists $restored->{error} ) {
            $workspace->release(1);
            die $restored->{error};    ## no critic (ErrorHandling::RequireCarping)
        }
    }
    _warn( $run, Test::Mutation::Message::warning( 'work-directory-stays', path => $workspace->directory ) )
      unless $workspace->release( $run->{config}->keep_work );
    return;
}

sub _restore_project ( $run, $workspace, $guard ) {
    Test::Mutation::Error::raise(
        'directory-unopenable',
        path   => $guard->{backup},
        reason => 'test processes still hold the workspace'
    ) unless Test::Mutation::Workspace::Processes::finish( $workspace->directory . '/processes' );
    my $changes = Test::Mutation::Tree::changes( $guard->{state}, _tree($run) );
    return _restore_changes( $run, $guard, $changes );
}

sub _restore_changes ( $run, $guard, $changes ) {
    for my $change ( $changes->@* ) {
        my $path = $change =~ s/\A\w+[ ]//r;
        Test::Mutation::Error::raise(
            'file-unreadable',
            path   => $path,
            reason => 'the original could not be backed up'
          )
          if grep { $_ eq $path || index( "$_/", "$path/" ) == 0 || index( "$path/", "$_/" ) == 0 }
          $guard->{opaque}->@*;
    }
    return Test::Mutation::Tree::restore( from => $guard->{backup}, to => $run->{project}, changes => $changes );
}

sub _prepare_work ($run) {
    my $work       = $run->{work} = $run->{workspace}->directory . '/work';
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
        next                                                      if ref $entry;
        return Test::Mutation::Source::read_bytes("$entry/$file") if -f "$entry/$file";
    }
    die Test::Mutation::Message::text_of( 'shim-missing', file => $file ) . "\n";
}

sub _first_line ( $run, $path ) {
    if ( !exists $run->{first}{$path} ) {
        open my $handle, '<', "$run->{root}/$path"
          or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
        $run->{first}{$path} = readline $handle;
        close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    }
    return $run->{first}{$path};
}

sub _remove_disk_spec ($spec) {
    my $path = "$spec.disk";
    unlink $path
      or $! == Errno::ENOENT()
      or Test::Mutation::Error::raise( 'file-unremovable', path => $path, reason => "$!" );
    return;
}

sub _spec ( $run, $root, $name, $trace, $targets ) {
    my $path  = "$run->{work}/$name.spec";
    my @lines = ( "trace\t" . ( $trace ? 1 : 0 ) );
    push @lines, "placed\t1"     if defined $run->{copies};
    push @lines, "trace_eval\t1" if $run->{trace_eval};
    _remove_disk_spec($path);
    for my $target ( $targets->@* ) {
        my @original = $root ne $run->{project} ? $run->{project} . substr( $target->[0], length $root ) : ();
        push @lines, join "\t", 'target', $target->@*, @original;
        my $relative = substr $target->[0], length($root) + 1;
        next unless defined $run->{copies};
        push @lines, "extract\t$target->[0]"
          if $run->{witness}{$relative} && defined $run->{witness}{$relative}{extract};
        next unless $trace && $relative =~ m{\A(?:bin|script)/} && -f $target->[0];
        my $headers = Test::Mutation::Workspace::Slot::twins( $root, $relative,
            Test::Mutation::Source::read_bytes( $target->[0] ) );
        push @lines, map { "command\t$target->[0]\t$root/$_" } sort keys %$headers;
    }
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

sub _write_mutant ( $run, $source, $mutant, $root, $raw = 0 ) {
    my $file  = "$run->{work}/mutants/" . $mutant->id . '.pm';
    my $text  = $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement );
    my $bytes = $source->to_bytes($text);
    _spew( $file, $bytes );
    my $served = $file;
    if ( defined $run->{copies} ) {
        my $placed = $bytes;
        if ( !$raw && ( my $witness = $run->{witness}{ $mutant->path } ) ) {
            my $at = $witness->{offset};
            if ( $mutant->end <= $at ) {
                $at += length( $mutant->replacement ) - ( $mutant->end - $mutant->start );
            }
            elsif ( $mutant->start < $at ) {
                $at = $mutant->start;
            }
            $placed = _marked_bytes( $run, $source, $text, $at );
        }
        Test::Mutation::Workspace::Slot::place( $root, $mutant->path, $source->to_bytes( $source->text ), $placed );
        $served = "$root/" . $mutant->path;
    }
    my $targets = target_pairs( $root, $run->{targets} ? $run->{targets} : [], $mutant->path, $served );
    my $spec    = _spec( $run, $root, 'mutants/' . $mutant->id, 0, $targets );
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
        $run->{workspace} = Test::Mutation::Workspace::acquire($root);
        _copy_project($run) unless $config->in_place;
        my $where = $run->{root};
        Test::Mutation::Error::raise( 'source-changed', path => $source->path )
          if Test::Mutation::Source::read_bytes( "$where/" . $source->path ) ne $source->to_bytes( $source->text );
        _prepare_work($run);
        my ( undef, $spec ) = _write_mutant( $run, $source, $mutant, $where );
        my $environment = Test::Mutation::Launch::test_command(
            perl    => $^X,
            root    => $where,
            program => $command->[0],
            tmp     => "$run->{work}/tmp",
            lib     => $config->lib,
            switch  => $config->switch,
            env     => \%ENV,
        )->{env};
        delete $environment->@{qw(HARNESS_ACTIVE HARNESS_VERSION)};
        local %ENV = ( %ENV, $environment->%*, $config->in_place ? _environment( $run, $spec, $where ) : () );
        my $lease = Test::Mutation::Workspace::Processes::inherit( $run->{workspace}->directory . '/processes' );

        # A command that cannot start ends exec with one line of the tool, and the warning of Perl would add another.
        no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        my $previous = Cwd::getcwd();
        chdir $where or Test::Mutation::Error::raise( 'test-directory-closed', directory => $where, reason => "$!" );
        return Test::Mutation::Try::with_cleanup(
            sub {
                my $status = system { $command->[0] } $command->@*;
                return [ $status, $! == Errno::ENOENT(), "$!" ];
            },
            sub {
                chdir $previous
                  or Test::Mutation::Error::raise( 'test-directory-closed', directory => $previous, reason => "$!" );
            },
        );
    };

    # A signal for the tool alone waits while the command runs, and it ends the work once the work directory is gone.
    my $ran = Test::Mutation::Signals::watch(
        sub {
            Test::Mutation::Try::with_cleanup( $work, sub { _release_workspace($run) } );
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

sub _launch ( $run, $root, $tmp, $source, %task ) {
    return Test::Mutation::Launch::test_command(
        perl   => $run->{perl},
        root   => $root,
        tmp    => $tmp,
        env    => \%ENV,
        lib    => $run->{config}->lib,
        switch => $run->{config}->switch,
        first  => _first_line( $run, $source ),
        %task,
    );
}

sub _test_task ( $run, %arg ) {
    my $sequence = ++$run->{sequence};
    my $work     = $run->{work};
    my $tmp      = "$work/tmp/$sequence";
    Test::Mutation::Tree::make($tmp);
    my @identity = ( stat $tmp )[ 0, 1 ];
    my $record   = "$work/records/" . join( '-', @identity );
    Test::Mutation::Tree::make($record);
    my $spec = $arg{spec};

    if ( $run->{try_disk} || $run->{disk_test}{ $arg{test} } ) {
        my $disk = "$spec.disk";
        _spew( $disk, Test::Mutation::Source::read_bytes($spec) . "observe\t1\n" ) unless -e $disk;
        $spec = $disk;
    }
    my $launch = _launch(
        $run, $arg{root}, $tmp, $arg{test},
        program => $arg{test},
        shim    => { generation => $run->{generation}, directory => "$work/shim", record => $record, spec => $spec },
    );
    return {
        $launch->%*,
        cwd => $arg{root},
        $run->{task_descriptor}
        ? ( observation => { directory => $tmp, descriptor => fileno( $run->{task_descriptor} ) } )
        : (),
        lease           => $run->{workspace}->directory . '/processes',
        timeout         => $arg{timeout},
        output_limit    => $OUTPUT_LIMIT,
        stop_on_failure => $arg{stop_on_failure},
        payload         => {
            $arg{payload}->%*,
            test    => $arg{test},
            record  => $record,
            tmp     => $tmp,
            targets => [ map { "$arg{root}/$_" } $run->{targets}->@* ]
        },
    };
}

sub _collect ($task) {
    my $payload = $task->{payload};
    my $record  = Test::Mutation::Record::read_directory( $payload->{record}, $payload->{targets} );
    _discard( $payload->{record}, $payload->{tmp} );
    return $record;
}

# Runs tests against the unmodified sources, which the hook serves as it serves a mutant.
# `counted` names the count of the work that the runs of these tests add to.
sub _unmodified ( $run, $name, $trace, $jobs, $tests, $counted ) {
    my $root  = $run->{root};
    my $spec  = _spec( $run, $root, $name, $trace, [ map { [ "$root/$_", "$root/$_" ] } $run->{targets}->@* ] );
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

sub _prepare_witnesses ($run) {
    $run->{task_descriptor} = Test::Mutation::Witness::reserve( $run->{workspace}->directory . '/processes' );
    my $targets = $run->{targets};
    for my $index ( keys $targets->@* ) {
        my $path = $targets->[$index];
        my $at   = Test::Mutation::Syntax::PPI::witness_offsets( $run->{sources}{$path} );
        $run->{witness}{$path} = { index => $index, first => $at->[0], offset => $at->[1], extract => $at->[2] } if $at;
    }
    return;
}

sub _marked_bytes ( $run, $source, $text, $at ) {
    my $witness = $run->{witness}{ $source->path };
    return $source->to_bytes(
        Test::Mutation::Witness::insert(
            $text,                  $at,
            $run->{generation},     $witness->{index},
            "$run->{work}/records", fileno( $run->{task_descriptor} )
        )
    );
}

sub _mark_originals ( $run, $root, $install, @paths ) {
    for my $path ( @paths ? @paths : sort keys $run->{witness}->%* ) {
        my $source = $run->{sources}{$path};
        my $raw    = $source->to_bytes( $source->text );
        my $marked = _marked_bytes( $run, $source, $source->text, $run->{witness}{$path}{offset} );
        my ( $before, $after ) = $install ? ( $raw, $marked ) : ( $marked, $raw );
        next if !-f "$root/$path" || Test::Mutation::Source::read_bytes("$root/$path") ne $before;
        Test::Mutation::Workspace::Slot::place( $root, $path, $before, $after );
    }
    return;
}

sub _observed_baseline ( $run, $tests ) {
    _mark_originals( $run, $run->{root}, 1 ) if $run->{task_descriptor};
    my $original = defined $run->{copies} ? _tree($run) : undef;
    my $baseline = _baseline( $run, $tests, $run->{targets} );
    if ( defined $original ) {
        $run->{baseline_changed} = Test::Mutation::Tree::changes( $original, _tree($run) )->@* ? 1 : 0;
    }
    _mark_originals( $run, $run->{root}, 0 ) if $run->{task_descriptor};
    return $baseline;
}

sub _disk_baseline ( $run, $pass, $outcome, $failed ) {
    my @completed = grep { _ending( $outcome->{$_}{result} ) eq 'fail' } $failed->@*;
    return unless @completed;
    my $disk;
    {
        local $run->{try_disk} = 1;
        $disk = $pass->( 1, \@completed, 'verifications' );
    }
    my @passed = grep { $disk->{$_}{result}{passed} } @completed;
    return unless @passed;
    my $hooked = $pass->( 1, \@passed, 'verifications' );
    for my $test (@passed) {
        next if $hooked->{$test}{result}{passed};
        $outcome->{$test} = $disk->{$test};
        $run->{disk_test}{$test} = 1;
    }
    return;
}

sub _baseline ( $run, $tests, $targets ) {
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

    if ( @failed && defined $run->{copies} ) {
        _disk_baseline( $run, $pass, $outcome, \@failed );
        @failed = grep { !$outcome->{$_}{result}{passed} } @failed;
    }
    if ( @failed && $run->{task_descriptor} ) {
        _raw_baseline( $run, \@failed, $outcome );
        @failed = grep { !$outcome->{$_}{result}{passed} } @failed;
    }
    _trace_blind( $run, $outcome ) if !@failed && $run->{task_descriptor} && $run->{config}->coverage eq 'line';
    _observe_in_place_loads( $run, $tests, $targets, $outcome ) if !@failed && $run->{guard};
    my ( $records, $breakable ) = _baseline_records( $run, $tests, $targets, $outcome );
    return {
        tests         => $records,
        breakable     => $breakable,
        parallel_safe => $parallel_safe,
        failures      => [ map { _failure( $_, $outcome->{$_}{result} ) } @failed ],
    };
}

sub _observe_in_place_loads ( $run, $tests, $targets, $outcome ) {
    my $project = $run->{project};
    my %unknown;
    for my $test (@$tests) {
        my $record  = $outcome->{$test}{record};
        my @missing = grep {
            my $path = "$project/$_";
            !$record->{served}{$path} && !$record->{bypassed}{$path} && !$record->{outside}{$path};
        } @$targets;
        $unknown{$test} = \@missing if @missing;
    }
    my @probe_tests = sort keys %unknown;
    return unless @probe_tests;
    local $run->{name} = File::Basename::basename($project);
    my $probe = _control_copy( $run, $run->{guard}{backup} );
    local $run->{root}            = $probe;
    local $run->{copies}          = $probe;
    local $run->{first}           = {};
    local $run->{witness}         = {};
    local $run->{task_descriptor} = undef;
    _prepare_witnesses($run);
    _mark_originals( $run, $probe, 1 );
    my $observed = _unmodified( $run, 'in-place-loads', 0, 1, \@probe_tests, 'verifications' );

    for my $test (@probe_tests) {
        next unless $observed->{$test}{result}{passed};
        for my $path ( $unknown{$test}->@* ) {
            my $record = $observed->{$test}{record};
            $outcome->{$test}{record}{bypassed}{"$project/$path"} = 1 if $record->{compiled}{"$probe/$path"};
        }
    }
    _discard($probe);
    return;
}

sub _baseline_records ( $run, $tests, $targets, $outcome ) {
    my ( %tests, %breakable );
    for my $test ( $tests->@* ) {
        my ( $result, $record ) = $outcome->{$test}->@{qw(result record)};
        my ( %files, %anomalies );
        for my $path ( $targets->@* ) {
            my $absolute = ( $outcome->{$test}{root} || $run->{root} ) . "/$path";
            my $evidence = Test::Mutation::Evidence::target( $record, $absolute );
            $files{$path} = $evidence->{coverage}       if $evidence->{coverage};
            $files{$path} = { traced => 0, hits => {} } if $run->{sensitive}{$test}{$path};
            my $lines = $evidence->{breakable};
            $breakable{$path} = { ( $breakable{$path} ? $breakable{$path}->%* : () ), $lines->%* } if $lines;
            my $anomaly = $evidence->{anomaly} or next;
            if ( $anomaly->{reason} eq 'loaded-around-hook' ) {
                _warn( $run, Test::Mutation::Message::warning( 'loaded-around-hook', test => $test, path => $path ) );
                next unless $run->{guard};
            }
            $anomalies{$path} = $anomaly;
            $files{$path}     = { traced => 0, hits => {} };
        }
        $tests{$test} =
          { duration => $result->{duration}, files => \%files, early => $result->{early}, anomalies => \%anomalies };
    }
    return ( \%tests, \%breakable );
}

sub _trace_blind ( $run, $outcome ) {
    my $original = $run->{root};
    my ( %tests, %paths );
    for my $test ( sort keys $outcome->%* ) {
        my $served = $outcome->{$test}{record}{served};
        for my $path ( keys $run->{witness}->%* ) {
            my $coverage = $served->{"$original/$path"};
            next if !$coverage || $coverage->{traced} || $run->{sensitive}{$test}{$path};
            push $tests{$test}->@*, $path;
            $paths{$path} = 1;
        }
    }
    return unless keys %tests;
    my $probe = _control_copy( $run, $original );
    for my $path ( sort keys %paths ) {
        my $source = Test::Mutation::Source->from_bytes(
            path  => $path,
            bytes => Test::Mutation::Source::read_bytes("$probe/$path"),
        );
        my $witness = $run->{witness}{$path};
        my $text    = $source->text;
        for my $at ( grep { defined } $witness->@{qw(extract first)} ) {
            $text = Test::Mutation::Witness::trace(
                text       => $text,
                offset     => $at,
                line       => $source->position_of($at)->[0],
                generation => $run->{generation},
                index      => $witness->{index},
                target     => "$probe/$path",
                work       => $run->{work},
                descriptor => fileno( $run->{task_descriptor} ),
            );
        }
        Test::Mutation::Workspace::Slot::place(
            $probe, $path,
            $source->to_bytes( $source->text ),
            $source->to_bytes($text)
        );
    }
    local $run->{root}       = $probe;
    local $run->{first}      = {};
    local $run->{trace_eval} = 1;
    my $observed = _unmodified( $run, 'trace-lines', 1, $run->{jobs}, [ sort keys %tests ], 'verifications' );
    for my $test ( sort keys %tests ) {
        next unless $observed->{$test}{result}{passed};
        my $record = $observed->{$test}{record};
        for my $path ( $tests{$test}->@* ) {
            my $read = Test::Mutation::Evidence::target( $record, "$probe/$path" );
            next if $read->{anomaly} || !$read->{coverage} || !$read->{coverage}{traced};
            $outcome->{$test}{record}{served}{"$original/$path"}    = $read->{coverage};
            $outcome->{$test}{record}{breakable}{"$original/$path"} = $read->{breakable} if $read->{breakable};
        }
    }
    _discard($probe);
    return;
}

sub _raw_trial ( $run, $root, $test ) {
    local $run->{root}     = $root;
    local $run->{first}    = {};
    local $run->{try_disk} = 1;
    my $outcome = _unmodified( $run, 'source-check-' . ++$run->{sequence}, 0, 1, [$test], 'verifications' );
    return { $outcome->{$test}->%*, root => $root };
}

sub _raw_baseline ( $run, $tests, $outcome ) {
    my @tests = grep { _ending( $outcome->{$_}{result} ) eq 'fail' } $tests->@*;
    return unless @tests;
    my $clean = _control_copy( $run, $run->{root} );
    _mark_originals( $run, $clean, 0 );
    for my $test (@tests) {
        my $trial = _control_copy( $run, $clean );
        my $raw   = _raw_trial( $run, $trial, $test );
        _discard($trial);
        next unless $raw->{result}{passed};
        for my $path ( sort keys $run->{witness}->%* ) {
            my $probe = _control_copy( $run, $clean );
            _mark_originals( $run, $probe, 1, $path );
            my $observation = _raw_trial( $run, $probe, $test );
            _discard($probe);
            $run->{sensitive}{$test}{$path} = 1 if _ending( $observation->{result} ) eq 'fail';
        }
        if ( keys $run->{sensitive}{$test}->%* ) {
            $outcome->{$test} = $raw;
            $run->{disk_test}{$test} = 1;
        }
    }
    _discard($clean);
    return;
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
        _release( $run, $job );
        $entry_of{ $job->{mutant}->id } = _finish( $run, $job );
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
    _save_cache( $run, $cache, \@entries ) if $cache;
    _ignore_repeated_code( $run, \@entries );
    return \@entries;
}

sub _tree ($run) {
    return _walk(
        $run, $run->{root}, '.git',
        map { _inside( $run->{project}, $_ ) } $run->{config}->cache_dir,
        $run->{config}->report_dir
    );
}

sub _begin_in_place ( $run, $baseline ) {
    my $guard = $run->{guard};
    $run->{jobs} = 1;
    my $changes = Test::Mutation::Tree::changes( $guard->{state}, _tree($run) );
    return unless $changes->@*;
    _restore_changes( $run, $guard, $changes );
    $run->{setup_tests} = [ sort keys $baseline->{tests}->%* ];
    return;
}

sub _prepare_in_place_test ( $run, $job, $test ) {
    _release( $run, $job ) if $run->{setup_tests};
    $job->{used_project} = 1;
    my @earlier = grep { $_ lt $test } @{ $run->{setup_tests} || [] };
    return unless @earlier;
    my $outcome = _unmodified( $run, 'setup-' . ++$run->{sequence}, 0, 1, \@earlier, 'verifications' );
    my ($failed) = grep { !$outcome->{$_}{result}{passed} } @earlier;
    return unless defined $failed;
    return { reason => 'unstable-test', detail => "$failed failed while preparing the original state for $test" };
}

sub _confirm_after_restore ( $run, $job, $guard ) {
    my $verdict = $job->{verdict};
    return unless ( $verdict->{status} || q{} ) eq 'Killed';
    my $test     = $verdict->{by};
    my $observed = _unmodified( $run, 'restored-' . ++$run->{sequence}, 0, 1, [$test], 'verifications' );
    my $changes  = Test::Mutation::Tree::changes( $guard->{state}, _tree($run) );
    _restore_changes( $run, $guard, $changes );
    return if $observed->{$test}{result}{passed};
    $verdict->@{qw(status reason detail)} =
      ( 'NoVerdict', 'project-changed', "$test still fails without a mutant after restoring the project" );
    return;
}

sub _changed_paths ( $run, $changes ) {
    my @named   = $changes->@[ 0 .. List::Util::min( $changes->$#*, $CHANGES_NAMED - 1 ) ];
    my $rest    = $changes->@* - @named;
    my $changed = join( ', ', @named ) . ( $rest ? " and $rest more" : q{} );
    _warn( $run, Test::Mutation::Message::warning( 'project-changed', changes => $changed ) );

    return;
}

sub _after_task ( $run, $baseline, $task, $result ) {
    my $job  = $task->{payload}{job};
    my $kind = $task->{payload}{kind};
    _discard( $task->{payload}{tmp} ) if $kind ne 'test';
    my $check =
        $kind eq 'test'      ? _after_test( $run, $baseline, $task, $result )
      : $kind =~ /\Asyntax-/ ? _after_syntax( $run, $baseline, $task, $result )
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

            # A failed restore retires the slot, so confirmation starts from a new copy of the reference tree.
            delete $job->{restore_error};
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
        $digest{$path} = Digest::SHA::sha256_hex( Test::Mutation::Source::read_bytes("$root/$path") )
          if !defined $digest{$path};
        return $digest{$path};
    };
    my @tests       = sort keys $baseline->{tests}->%*;
    my @interpreter = map { defined ? $_ : q{} } ( stat $run->{perl} )[ 7, 9 ];
    my @shared      = (
        $VERSION,
        $run->{perl},
        @interpreter,
        scalar $config->lib->@*,
        $config->lib->@*,
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

sub _control_copy ( $run, $from ) {
    my @skip =
      $from eq $run->{project}
      ? ( '.git', map { _inside( $from, $_ ) } $run->{config}->cache_dir, $run->{config}->report_dir )
      : ();
    my $link = $from eq $run->{project} ? $run->{config}->link : [];
    return _new_copy( $run, "$run->{work}/controls/" . ++$run->{control_sequence}, $from, \@skip, $link );
}

sub _control_pass ( $run, $root, $tests ) {
    local $run->{root}  = $root;
    local $run->{first} = {};
    my $outcomes = _unmodified( $run, 'control-' . ++$run->{sequence}, 0, 1, $tests, 'verifications' );
    return !grep { !$outcomes->{$_}{result}{passed} } $tests->@*;
}

sub _verified_reference ( $run, $baseline, $test ) {
    my $after  = _control_copy( $run, $run->{root} );
    my $passed = _control_pass( $run, $after, [$test] );
    _discard($after);
    return { same => 1 } if $passed;
    my $clean = $run->{pristine} ||= _control_copy( $run, $run->{project} );
    my $trial = _control_copy( $run, $clean );
    $passed = _control_pass( $run, $trial, [$test] );
    _discard($trial);
    return { root => $clean } if $passed;

    my @earlier = sort grep { $_ lt $test } keys $baseline->{tests}->%*;
    if (@earlier) {
        my $ordered = _control_copy( $run, $clean );
        if ( _control_pass( $run, $ordered, \@earlier ) ) {
            my $check = _control_copy( $run, $ordered );
            my $ok    = _control_pass( $run, $check, [$test] );
            _discard($check);
            return { root => $ordered } if $ok;
        }
        _discard($ordered);
    }
    return { unstable => 1 };
}

sub _after_test ( $run, $baseline, $task, $result ) {
    my $payload  = $task->{payload};
    my $job      = $payload->{job};
    my $path     = $job->{mutant}->path;
    my $absolute = _job_root( $run, $job ) . "/$path";
    my $evidence = Test::Mutation::Evidence::target( _collect($task), $absolute );
    $job->{duration} += $result->{duration};
    $job->{outcome} = {
        test        => $payload->{test},
        result      => _ending($result),
        served      => $evidence->{coverage} ? 1 : 0,
        load_failed => $evidence->{load_failed},
        bypassed    => 0,
        anomaly     => $evidence->{anomaly} || $payload->{baseline_anomaly},
        syntax      => $job->{syntax},
    };
    if ( $payload->{confirm_read} ) {
        $job->{outcome}{read_check} = _ending($result);
        return;
    }
    if ( $run->{baseline_changed} && !$result->{passed} && !$job->{outcome}{anomaly} ) {
        my $test  = $payload->{test};
        my $proof = $run->{controls}{$test} ||= _verified_reference( $run, $baseline, $test );
        if ( $proof->{unstable} ) {
            $job->{outcome}{anomaly} = { reason => 'unstable-test', detail => "$test failed without the mutant" };
        }
        elsif ( defined $proof->{root}
            && ( !defined $job->{starting_tree} || $job->{starting_tree} ne $proof->{root} ) )
        {
            _release( $run, $job );
            return if defined $job->{restore_error};
            $run->{stats}{verifications}++;
            $job->{starting_tree} = $proof->{root};
            delete $job->{spec};
            return _next_test( $run, $job, $baseline );
        }
    }
    return _check_load( $run, $baseline, $job );
}

sub _check_load ( $run, $baseline, $job ) {
    return if $job->{outcome}{anomaly};
    my $path = $job->{mutant}->path;
    if ( !$job->{outcome}{served} ) {
        return unless defined $run->{copies} && $job->{outcome}{result} eq 'fail';
        $job->{check_read} = 1;
        return _verify_read( $run, $baseline, $job ) if defined $job->{syntax};
    }
    else {
        return if !$job->{outcome}{load_failed} || defined $job->{syntax};
    }
    my $known = $run->{syntax_of_original}{$path};
    return _compile_task( $run, $job, 'syntax-original', "$run->{root}/$path", '-c' ) if !defined $known;
    return _compile_task( $run, $job, 'syntax-mutant',   $job->{file},         '-c' ) if $known || $job->{check_read};
    $job->{outcome}{syntax} = $job->{syntax} = 'standalone';
    return;
}

# A failed check of the original says that the source does not compile alone, so its mutants say nothing more.
sub _after_syntax ( $run, $baseline, $task, $result ) {
    my $job      = $task->{payload}{job};
    my $path     = $job->{mutant}->path;
    my $ok       = $result->{exit} == 0 && !$result->{timed_out} ? 1 : 0;
    my $original = $task->{payload}{kind} eq 'syntax-original';
    if ($original) {
        $run->{syntax_of_original}{$path} = $ok;
        return _compile_task( $run, $job, 'syntax-mutant', $job->{file}, '-c' ) if $ok || $job->{check_read};
        _warn( $run, Test::Mutation::Message::warning( 'syntax-check-failed', path => $path ) );
    }
    $job->{outcome}{syntax} = $job->{syntax} =
      !$run->{syntax_of_original}{$path} ? 'standalone' : $ok ? 'ok' : 'compile-phase';
    return _verify_read( $run, $baseline, $job ) if $job->{check_read};
    return;
}

sub _verify_read ( $run, $baseline, $job ) {
    delete $job->{check_read};
    if ( $job->{syntax} eq 'compile-phase' ) {
        $job->{outcome}{read_check} = 'compile-error';
        return;
    }
    _release( $run, $job );
    return if defined $job->{restore_error};
    delete $job->{spec};
    my $repeat = _next_test( $run, $job, $baseline );
    $repeat->{payload}{confirm_read} = 1;
    $run->{stats}{verifications}++;
    return $repeat;
}

sub _next_test ( $run, $job, $baseline ) {
    my $config    = $run->{config};
    my $mutant    = $job->{mutant};
    my $test      = $job->{tests}[ $job->{index} ];
    my $raw       = $run->{sensitive}{$test} && keys $run->{sensitive}{$test}->%* ? 1 : 0;
    my $proof     = $run->{controls}{$test};
    my $reference = $proof && $proof->{root} ? $proof->{root} : $run->{root};
    if ( defined $job->{spec} && ( $raw != $job->{raw} || $job->{copy} && $job->{copy}{reference} ne $reference ) ) {
        _release( $run, $job );
        return if defined $job->{restore_error};
        delete $job->{spec};
    }
    $job->{starting_tree} = $reference;
    if ( !defined $job->{spec} ) {
        $job->@{qw(file spec)} =
          _write_mutant( $run, $run->{sources}{ $mutant->path }, $mutant, _job_root( $run, $job ), $raw );
        $job->{raw} = $raw;
    }
    my $setup    = $run->{guard} ? _prepare_in_place_test( $run, $job, $test ) : undef;
    my $anomaly  = $setup || $baseline->{tests}{$test}{anomalies}{ $mutant->path };
    my $duration = $baseline->{tests}{$test}{duration} * $config->timeout_factor;
    return _test_task(
        $run,
        root            => _job_root( $run, $job ),
        test            => $test,
        spec            => $job->{spec},
        timeout         => List::Util::max( $duration, $config->timeout_floor ),
        stop_on_failure => $baseline->{tests}{$test}{early} ? 0 : 1,
        payload         => { kind => 'test', job => $job, $anomaly ? ( baseline_anomaly => $anomaly ) : () },
    );
}

sub _compile_task ( $run, $job, $kind, $file, $switch ) {
    my $config = $run->{config};
    my $root   = _job_root( $run, $job );
    $run->{stats}{compiles}++;
    my $tmp = "$run->{work}/tmp/" . ++$run->{sequence};
    Test::Mutation::Tree::make($tmp);
    my $launch = _launch( $run, $root, $tmp, $job->{mutant}->path, program => $file, arguments => [$switch] );
    return {
        command         => $launch->{command},
        env             => { $launch->{env}->%*, PERL_HASH_SEED => '0', PERL_PERTURB_KEYS => '0' },
        cwd             => $root,
        lease           => $run->{workspace}->directory . '/processes',
        timeout         => $config->baseline_timeout,
        output_limit    => $OUTPUT_LIMIT,
        stop_on_failure => 0,
        payload         => { kind => $kind, job => $job, tmp => $tmp },
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
    _remove_disk_spec( $job->{spec} ) if defined $job->{spec};
    unlink grep { defined } $job->@{qw(file spec)};
    my $verdict = Test::Mutation::Verdict::conclude( $job->{verdict} );
    my $mutant  = $job->{mutant};
    my $code    = defined $job->{code} ? $job->{code} : q{};
    my ( $status, $reason, $detail ) = $verdict->@{qw(status reason detail)};
    if ( defined $job->{restore_error} ) {
        ( $status, $reason, $detail ) = ( 'NoVerdict', 'slot-not-restored', $job->{restore_error} );
    }
    elsif ( length $code ) {
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
The listener receives C<phase>, C<analyzed>, C<baseline>, and C<mutant> events with a hash reference of details.
Each C<phase> event gives the stage name and its start time.

=head2 phases

Returns the ordered names of the phases a complete measurement can enter.

=head2 run_command

    my $status = Test::Mutation::Runner::run_command( $config, $source, $mutant, [ 'prove', '-l', 't/a.t' ] );

Runs a command with one mutant active and returns its exit status.
The command runs in a private copy containing the replacement, including when the command starts a tainted Perl process.

=head2 target_pairs

    my $pairs = Test::Mutation::Runner::target_pairs( $root, \@paths, $mutated_path, $mutant_file );

Returns the targets of a mutant run as pairs of an original file and the file to serve in its place.
Every source file goes through the hook, so a mutant run differs from the unmodified run in the text of one file alone.

=head2 shim_text

Returns the source of L<Test::Mutation::Shim> renamed for a generation.
A run inside another run uses the next generation, so both shims work in one process.

=cut
