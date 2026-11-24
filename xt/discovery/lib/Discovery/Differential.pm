package Discovery::Differential;
use v5.36;
use File::Path ();
use Discovery::Check;
use Discovery::Known;
use Discovery::Project;

# Each relation between two ways to run one project: the runs it needs, and the check of their results.
# The harness calls this code with the adapter, and the self-test calls it with the saboteurs of the adapter.

# A run that fails to measure leaves its relation without an observation, so its failure is the finding.
sub _related ( $name, $label, $runs, @arguments ) {
    my @broken   = map { Discovery::Check::findings( ['completes'], run => $_ ) } $runs->@*;
    my @found    = @broken ? @broken : Discovery::Check::findings( [$name], @arguments );
    my %seen     = map { ( "$label: $_" => 1 ) } @found;
    my @labelled = sort keys %seen;
    return @labelled;
}

sub jobs ( $engine, $project, %settings ) {
    my @runs = map { $engine->run( $project, %settings, jobs => $_ ) } 1, 3;
    return _related( 'jobs', 'jobs', \@runs, run => $runs[0], other => $runs[1] );
}

sub in_place ( $engine, $project, %settings ) {
    my @runs = ( $engine->run( $project, %settings ), $engine->run( $project, %settings, in_place => 1 ) );
    return _related( 'in-place', 'in-place', \@runs, run => $runs[0], other => $runs[1] );
}

sub coverage ( $engine, $project, %settings ) {
    my @runs = map { $engine->run( $project, %settings, coverage => $_ ) } 'line', 'file';
    return _related( 'coverage', 'coverage', \@runs, run => $runs[0], other => $runs[1] );
}

# The whole run comes first: a run with the default report directory removes the reports of the parts.
sub shard ( $engine, $project, %settings ) {
    my $whole  = $engine->run( $project, %settings );
    my @parts  = map { $engine->run( $project, %settings, shard => "$_/2", report => "mutation-report/part-$_" ) } 1, 2;
    my $merged = $engine->merge( $project, [ map { "mutation-report/part-$_/mutation.json" } 1, 2 ] );
    return _related( 'shard', 'shard', [ $whole, @parts, $merged ], run => $whole, other => $merged );
}

sub since ( $engine, $project, $revision, %settings ) {
    my @runs = ( $engine->run( $project, %settings ), $engine->run( $project, %settings, since => $revision ) );
    return _related( 'since', 'since', \@runs, run => $runs[0], other => $runs[1] );
}

# The first mutant of each status runs alone.
sub single ( $engine, $project, %settings ) {
    my $whole = $engine->run( $project, %settings );
    my %first;
    for my $id ( sort keys $whole->{status}->%* ) {
        $first{ $whole->{status}{$id} } = $id if !defined $first{ $whole->{status}{$id} };
    }
    my @alone = map { $engine->run( $project, %settings, mutants => [ $first{$_} ] ) } sort keys %first;
    return _related( 'single', 'single', [ $whole, @alone ], run => $whole, others => \@alone );
}

# The harness puts each replacement into a copy of the project itself and asks prove for every test.
# `each` limits the mutants of one status, and a mutant that times out stays out: prove has no limit of its own.
sub prove ( $engine, $project, $each, %settings ) {
    my $run   = $engine->run( $project, %settings );
    my @tests = sort keys $run->{tests}->%*;
    my ( %taken, %verdicts, $copy );
    for my $id ( sort keys $run->{status}->%* ) {
        my $status = $run->{status}{$id};
        next if $status !~ /\A(?:Killed|Survived|NoCoverage)\z/ || ( defined $each && ++$taken{$status} > $each );
        $copy ||= $project->copy;
        $verdicts{$id} = _proved( $project, $copy, $run->{mutants}{$id}, $id, \@tests );
    }
    $copy->discard if $copy;
    return _related( 'prove', 'prove', [$run], run => $run, verdicts => \%verdicts );
}

my %PROVED;

# The answer of prove for one mutant of one project stays the same, so a second question takes the first answer.
sub _proved ( $project, $copy, $mutant, $id, $tests ) {
    my $key = join "\0", $project->root, $id;
    if ( !$PROVED{$key} ) {
        my $text = $copy->text( $mutant->{path} );
        $copy->write( $mutant->{path}, Discovery::Known::spliced( $text, $mutant ) );
        $PROVED{$key} = { ( map { $_ => 'fail' } $tests->@* ), $copy->proves( $tests->@* )->%* };
        $copy->write( $mutant->{path}, $text );
    }
    return $PROVED{$key};
}

# The project of the cache relation: its one test takes rows from every kind of input that a result depends on.
# Each kind starts without a row, and a perturbation gives it the row that detects the survivor of the first cell.
my $ROW        = 'cell_1 2 2 1';
my $FIXED_TIME = 1_700_000_000;
my @FIRST      = ( [ 4, 1 ], [ 0, 2 ] );

my $TEST = <<'PERL';
use strict;
use warnings;
use lib 'extra', 't/lib', '<<outside>>';
use Known;
use Rows    ();
use Helper  ();
use Outside ();
my @more = ( Rows::rows(), Helper::rows(), Outside::rows(), eval { require Variant; Variant::rows() } );
if ( open my $data, '<', 'data/rows.txt' ) {
    chomp( my @lines = <$data> );
    close $data;
    push @more, grep { length } @lines;
}
push @more, $ENV{DISCOVERY_ROWS} if defined $ENV{DISCOVERY_ROWS};
my @rows = ( <<rows>> );
for my $text (@more) {
    my ( $cell, @rest ) = split q{ }, $text;
    my $want = pop @rest;
    push @rows, [ $cell, [@rest], $want ];
}
local $| = 1;
print '1..', scalar @rows, "\n";
my $number = 0;
for my $row (@rows) {
    my ( $cell, $arguments, $want ) = @{$row};
    my $got = Known->can($cell)->( @{$arguments} );
    $number++;
    print( ( defined $got && $got eq $want ? 'ok' : 'not ok' ), " $number - $cell\n" );
}
PERL

sub _cells (@first) {
    return Discovery::Known->new(
        tests => 1,
        cells => [
            { body => 'return $x >= $y ? 1 : 0', rows => [@first],     test => 't/a.t' },
            { body => 'return $x + $y',          rows => [ [ 2, 3 ] ], test => 't/a.t' },
        ],
    );
}

sub _provider ( $package, @rows ) {
    my $list = join ', ', map { Discovery::Known::quoted($_) } @rows;
    return "package $package;\nuse strict;\nuse warnings;\nsub rows { return ($list) }\n1;\n";
}

sub _spew ( $path, $content, $mode = undef ) {
    my ($directory) = $path =~ m{\A(.*)/};
    File::Path::make_path($directory);
    open my $handle, '>:raw', $path or die "write $path: $!";
    print {$handle} $content or die "write $path: $!";
    close $handle            or die "close $path: $!";
    chmod $mode, $path or die "chmod $path: $!" if defined $mode;
    utime $FIXED_TIME, $FIXED_TIME, $path or die "utime $path: $!";
    return;
}

sub _wrapper ($before) {
    return "#!/bin/sh\n${before}exec '$^X' \"\$@\"\n";
}

sub _test_text ( $known, $outside, @more ) {
    my $rows = join ', ', map {
        sprintf '[ %s, [ %s ], %s ]', Discovery::Known::quoted( $_->[0] ),
          join( ', ', map { Discovery::Known::quoted($_) } $_->[1]->@* ),
          Discovery::Known::quoted( $_->[2] )
    } $known->rows('t/a.t')->@*, @more;
    return $TEST =~ s/<<outside>>/$outside/r =~ s/<<rows>>/$rows/r;
}

# The bench holds the project, the cells before and after a perturbation, and the files that stand outside the project.
sub cache_bench () {
    my $project = Discovery::Project->new;
    my $scratch = $project->scratch;
    return {
        project => $project,
        plain   => _cells(@FIRST),
        more    => _cells( @FIRST, [ 2, 2 ] ),
        outside => "$scratch/outside",
        wrapper => "$scratch/perl",
        config  => "$scratch/plain.toml",
        variant => "$scratch/variant.toml",
    };
}

# Every file of the bench as it stands before a perturbation, with the cache that an earlier run left.
sub _pristine ( $bench, $cache ) {
    my $project = $bench->{project};
    my %file    = (
        'lib/Known.pm'       => $bench->{plain}->module('Known'),
        'lib/Rows.pm'        => _provider('Rows'),
        't/lib/Helper.pm'    => _provider('Helper'),
        'variant/Variant.pm' => _provider( 'Variant', $ROW ),
        'data/rows.txt'      => q{},
        't/a.t'              => _test_text( $bench->{plain}, $bench->{outside} ),
    );
    for my $path ( sort keys %file ) {
        my $text = $project->text($path);
        $project->write( $path, $file{$path}, time => $FIXED_TIME ) if !defined $text || $text ne $file{$path};
    }
    $project->remove($_) for 'extra', '.mutation';
    $project->write( '.mutation/cache.json', $cache ) if defined $cache;
    _spew( "$bench->{outside}/Outside.pm", _provider('Outside') );
    _spew( $bench->{wrapper}, _wrapper(q{}), oct '755' );
    _spew( $bench->{config},  qq{[test]\nswitches = ["-Ilib"]\n} );
    _spew( $bench->{variant}, qq{[test]\nswitches = ["-Ilib", "-Ivariant"]\n} );
    return;
}

# Each perturbation changes one kind of input and returns the settings that differ for the run after it.
my %PERTURB = (
    'test' => sub ($bench) {
        $bench->{project}
          ->write( 't/a.t', _test_text( $bench->{plain}, $bench->{outside}, [ 'cell_1', [ 2, 2 ], 1 ] ) );
        return;
    },
    'source' => sub ($bench) {
        $bench->{project}->write( 'lib/Rows.pm', _provider( 'Rows', $ROW ) );
        return;
    },
    'helper' => sub ($bench) {
        $bench->{project}->write( 't/lib/Helper.pm', _provider( 'Helper', $ROW ) );
        return;
    },
    'data-file' => sub ($bench) {
        $bench->{project}->write( 'data/rows.txt', "$ROW\n" );
        return;
    },
    'shadow' => sub ($bench) {
        $bench->{project}->write( 'extra/Helper.pm', _provider( 'Helper', $ROW ) );
        return;
    },
    'outside-inc' => sub ($bench) {
        _spew( "$bench->{outside}/Outside.pm", _provider( 'Outside', $ROW ) );
        return;
    },
    'environment' => sub ($bench) {
        return ( environment => { DISCOVERY_ROWS => $ROW } );
    },
    'launch' => sub ($bench) {
        return ( configuration => $bench->{variant} );
    },
    'interpreter' => sub ($bench) {
        _spew( $bench->{wrapper}, _wrapper("DISCOVERY_ROWS='$ROW'\nexport DISCOVERY_ROWS\n"), oct '755' );
        return;
    },
);

sub perturbations () {
    my @names = sort keys %PERTURB;
    return @names;
}

# A cold run fills the cache, a second run on the same inputs reuses it, and each perturbation then starts from that cache.
# Every result of the bench depends on its one test, so a run after a perturbation may reuse nothing.
# `selections` adds the runs of one mutant and of one part, which may reuse the records of the whole run.
sub cache ( $engine, $bench, %option ) {
    my $project  = $bench->{project};
    my @classes  = $option{classes} ? $option{classes}->@* : perturbations();
    my %settings = ( cache => 1, perl => $bench->{wrapper}, configuration => $bench->{config} );
    my @truth    = ( known => $bench->{plain}, coverage => 'line' );
    _pristine( $bench, undef );
    my $cold   = $engine->run( $project, %settings );
    my $filled = $project->text('.mutation/cache.json');
    my $again  = $engine->run( $project, %settings );
    my @found  = (
        _related( 'cache', 'cache cold', [$cold], run => $cold, @truth ),
        _related( 'cache', 'cache unchanged', [$again], run => $again, @truth, reuse => 'all' ),
    );

    for my $class (@classes) {
        _pristine( $bench, $filled );
        my %changed = $PERTURB{$class}->($bench);
        my $run     = $engine->run( $project, %settings, %changed, state => $class );
        push @found,
          _related(
            'cache', "cache perturbation=$class", [$run],
            run      => $run,
            known    => $bench->{more},
            coverage => 'line',
            reuse    => 'none',
            stored   => $engine->cache_ids($project),
          );
    }
    return @found if !$option{selections};

    my ($one) = grep { $cold->{status}{$_} eq 'Killed' } sort keys $cold->{status}->%*;
    for my $selection ( [ 'mutant', mutants => [$one] ], [ 'shard', shard => '1/2' ] ) {
        my ( $name, @selected ) = $selection->@*;
        _pristine( $bench, $filled );
        my $run = $engine->run( $project, %settings, @selected );
        push @found, _related( 'cache', "cache selection=$name", [$run], run => $run, @truth, reuse => 'all' );
    }
    return @found;
}

1;
