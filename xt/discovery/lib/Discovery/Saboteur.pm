package Discovery::Saboteur;
use v5.36;
use File::Path  ();
use POSIX       ();
use Time::HiRes ();

# Each saboteur is the adapter with one part replaced: it breaks one invariant, and the check of that invariant must say so.
# Damage is done for real in the files and processes of the run, so the observation code of the adapter is what detects it.

my $SLEEP_SECONDS = 30;
my @UNDO;

sub _spew ( $path, $content ) {
    open my $handle, '>:raw', $path or die "write $path: $!";
    print {$handle} $content or die "write $path: $!";
    close $handle            or die "close $path: $!";
    return;
}

sub _slurp ($path) {
    open my $handle, '<:raw', $path or die "read $path: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return $text;
}

sub _damage ($code) {
    return sub ($engine) {
        return $engine->with( damage => $code );
    };
}

sub _distort ($code) {
    return sub ($engine) {
        return $engine->with( distort => $code );
    };
}

sub _first_in ( $run, $path, @statuses ) {
    my %wanted = map { $_ => 1 } @statuses;
    my ($id) =
      grep { $wanted{ $run->{status}{$_} } && $run->{mutants}{$_}{path} =~ $path } sort keys $run->{status}->%*;
    die "the bench has no mutant with the status @statuses\n" if !defined $id;
    return $id;
}

sub _first ( $run, @statuses ) {
    return _first_in( $run, qr/./, @statuses );
}

# The sleeper leaves the harness as a grandchild, registers itself, and ends on its own after its sleep.
sub _leave_process ( $project, $temporary, $settings ) {
    my $registry = $project->registry;
    my $pid      = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        my $inner = fork;
        POSIX::_exit( defined $inner ? 0 : 1 ) if !defined $inner || $inner;
        if ( open my $handle, '>', "$registry/$$.new" ) {
            print {$handle} "the sleeper of the saboteur\n";
            close $handle;
            rename "$registry/$$.new", "$registry/$$";
        }
        exec {$^X} $^X, '-e', "sleep $SLEEP_SECONDS" or POSIX::_exit(127);
    }
    waitpid $pid, 0;
    my $deadline = Time::HiRes::time() + 5;
    while ( Time::HiRes::time() < $deadline ) {
        my @registered = glob "$registry/[0-9]*[0-9]";
        last if @registered;
        Time::HiRes::sleep(0.01);
    }
    return;
}

sub _rewrite_in_place ( $project, $temporary, $settings ) {
    my $path = $project->root . '/lib/Known.pm';
    my @time = ( stat $path )[ 8, 9 ];
    my $text = _slurp($path);
    _spew( $path, $text =~ s/warnings/warningz/r );
    utime @time, $path or die "utime $path: $!";
    push @UNDO, sub {
        _spew( $path, $text );
        utime @time, $path or die "utime $path: $!";
    };
    return;
}

my %SABOTEUR = (
    completes => {
        'a failing exit status' => _distort( sub ( $run, $settings ) { $run->{exit}     = 4 } ),
        'a lost report'         => _distort( sub ( $run, $settings ) { $run->{reported} = 0 } ),
        'a deadline'            => _distort( sub ( $run, $settings ) { $run->{hung}     = 1 } ),
    },
    I2 => { 'a process that outlives the run' => _damage( \&_leave_process ) },
    I3 => {
        'a directory in the temporary directory' => _damage(
            sub ( $project, $temporary, $settings ) {
                mkdir "$temporary/mutation-Ab12Cd" or die "mkdir: $!";
            }
        ),
        'a work directory in the project' => _damage(
            sub ( $project, $temporary, $settings ) {
                my $path = $project->root . '/.mutation/run-Ab12Cd';
                File::Path::make_path($path);
                push @UNDO, sub { File::Path::remove_tree($path) };
            }
        ),
    },
    I4 => {
        'a new file in the project' => _damage(
            sub ( $project, $temporary, $settings ) {
                my $path = $project->root . '/sabotage.txt';
                _spew( $path, "damage\n" );
                push @UNDO, sub { unlink $path };
            }
        ),
        'another mode of a file' => _damage(
            sub ( $project, $temporary, $settings ) {
                my $path = $project->root . '/t/a.t';
                my $mode = ( stat $path )[2] & oct '7777';
                chmod $mode ^ oct('100'), $path or die "chmod $path: $!";
                push @UNDO, sub { chmod $mode, $path };
            }
        ),
        'a rewrite of the same size with the old time' => _damage( \&_rewrite_in_place ),
    },
    I5 => {
        'a status outside the list' => _distort(
            sub ( $run, $settings ) {
                $run->{status}{ _first( $run, 'Killed' ) } = 'Zombie';
            }
        ),
        'a status without its reason' => _distort(
            sub ( $run, $settings ) {
                my $id = _first( $run, 'Killed' );
                $run->@{qw(status reason)} =
                  ( { $run->{status}->%*, $id => 'Timeout' }, { $run->{reason}->%*, $id => undef } );
            }
        ),
    },
    I6 => {
        'a deviation without its warning' => _distort(
            sub ( $run, $settings ) {
                $run->{warnings} = [];
            }
        ),
    },
    I8 => {
        'a kill that one loading style loses' => _distort(
            sub ( $run, $settings ) {
                $run->{status}{ _first_in( $run, qr/Require/, 'Killed' ) } = 'NoCoverage';
            }
        ),
        'a loading style without its mutants' => _distort(
            sub ( $run, $settings ) {
                for my $id ( grep { $run->{mutants}{$_}{path} =~ /Require/ } keys $run->{mutants}->%* ) {
                    delete $run->{$_}{$id} for qw(mutants status reason by covered);
                }
            }
        ),
    },
    I7 => {
        'a kill turned into a survivor' => _distort(
            sub ( $run, $settings ) {
                $run->{status}{ _first( $run, 'Killed' ) } = 'Survived';
            }
        ),
        'a survivor turned into a kill' => _distort(
            sub ( $run, $settings ) {
                my $id = _first( $run, 'Survived', 'NoCoverage' );
                $run->{status}{$id} = 'Killed';
                $run->{by}{$id}     = 't/a.t';
            }
        ),
        'a kill by another test' => _distort(
            sub ( $run, $settings ) {
                $run->{by}{ _first( $run, 'Killed' ) } = 't/absent.t';
            }
        ),
    },

    # The saboteurs of the reader checks replace a part of the reader adapter.
    'tap' => {
        'a reader that ignores plans' => sub ($reader) {
            return $reader->with( settle => sub ($state) { return { $state->%*, planned => $state->{seen} } } );
        },
        'a reader that ignores the end of the process' => sub ($reader) {
            return $reader->with( status => sub ( $exit, $signal ) { return ( 0, 0 ) } );
        },
    },
    'tap-prefix' => {
        'a reader that takes a todo for a failure' => sub ($reader) {
            return $reader->with( rewrite => sub ($line) { return $line =~ s/[#]\s*TODO.*//ir } );
        },
    },
);

sub names () {
    my @names = sort keys %SABOTEUR;
    return @names;
}

sub of ($name) {
    return $SABOTEUR{$name} || die "no saboteur is named $name\n";
}

# The benches share one project, so each saboteur names how its damage leaves again.
sub undo () {
    $_->() for reverse splice @UNDO;
    return;
}

1;
