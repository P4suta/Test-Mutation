package RealWorld;
use v5.36;
use JSON::PP   ();
use List::Util ();
use TOML::Tiny ();

# The logic of the real-world harness: the table of the runs, the record of one run, and the judge of a record.
# The program inside the container writes a record with these functions, and the gates on the host read it with them.
# Nothing here asks the tool what its report means, so a wrong report cannot excuse itself.

my @WARNING_KINDS = qw(around-the-hook no-stable-output other);
my @TEXTS         = qw(name version pathname sha256 shape);
my %FIELD         = map { $_ => 1 } @TEXTS, qw(build tests options config expect hash_seed);
my %EXPECTED      = map { $_ => 1 } qw(mutants score warnings seconds);
my $NUMBER        = qr/\A[0-9]+(?:[.][0-9]+)?\z/;

sub _words ($value) {
    return ref $value eq 'ARRAY' && !grep { ref || !length } $value->@* ? 1 : 0;
}

sub _band ($value) {
    return 0 if ref $value ne 'ARRAY' || $value->@* != 2 || grep { ref || $_ !~ $NUMBER } $value->@*;
    return $value->[0] <= $value->[1] ? 1 : 0;
}

sub _expectation ( $run, $expect ) {
    die "$run needs an expectation\n" if ref $expect ne 'HASH';
    my @unknown = sort grep { !$EXPECTED{$_} } keys $expect->%*;
    die "$run has no field named expect.$unknown[0]\n" if @unknown;
    for my $field (qw(mutants warnings seconds)) {
        die "$run needs $field\n" if !defined $expect->{$field};
    }
    for my $band ( grep { defined $expect->{$_} } qw(mutants score) ) {
        die "$run: $band is no band\n" if !_band( $expect->{$band} );
    }
    die "$run: warnings is no list of words\n" if !_words( $expect->{warnings} );
    my %kind    = map  { $_ => 1 } @WARNING_KINDS;
    my @unnamed = grep { !$kind{$_} } $expect->{warnings}->@*;
    die "$run: no kind of warning is named $unnamed[0]\n" if @unnamed;
    die "$run: seconds is no time\n" if ref $expect->{seconds} || $expect->{seconds} !~ /\A[1-9][0-9]*\z/;
    return {
        mutants  => [ map { 0 + $_ } $expect->{mutants}->@* ],
        score    => defined $expect->{score} ? [ map { 0 + $_ } $expect->{score}->@* ] : undef,
        warnings => [ $expect->{warnings}->@* ],
        seconds  => 0 + $expect->{seconds},
    };
}

sub _run ( $run, $table ) {
    my @unknown = sort grep { !$FIELD{$_} } keys $table->%*;
    die "$run has no field named $unknown[0]\n" if @unknown;
    for my $field (@TEXTS) {
        die "$run needs a $field\n" if !defined $table->{$field} || ref $table->{$field} || !length $table->{$field};
    }
    my ( $name, $version ) = $table->@{qw(name version)};
    die "$run: the sha256 is no digest of 64 hexadecimal digits\n" if $table->{sha256} !~ /\A[0-9a-f]{64}\z/;
    die "$run: the pathname names no archive of $name $version\n"
      if $table->{pathname} !~ m{\A[A-Z]/[A-Z]{2}/[A-Z0-9-]+/\Q$name-$version\E[.]tar[.]gz\z};

    my $build   = defined $table->{build}   ? $table->{build}   : [];
    my $options = defined $table->{options} ? $table->{options} : [];
    die "$run: tests is no command\n"          if !_words( $table->{tests} ) || !$table->{tests}->@*;
    die "$run: build is no list of commands\n" if ref $build ne 'ARRAY' || grep { !_words($_) || !$_->@* } $build->@*;
    die "$run: options is no list of words\n"  if !_words($options);
    die "$run: config is no text\n"            if ref $table->{config};
    my $seed = $table->{hash_seed};
    die "$run: hash_seed needs whole hexadecimal bytes\n"
      if defined $seed && $seed !~ /\A(?:[0-9a-fA-F]{2})+\z/;
    return {
        run => $run,
        ( map { $_ => $table->{$_} } @TEXTS ),
        build     => $build,
        tests     => $table->{tests},
        options   => $options,
        config    => $table->{config},
        hash_seed => $seed,
        expect    => _expectation( $run, $table->{expect} ),
    };
}

# The runs of the table in the order of their names, each with every field in place.
sub runs ($text) {
    my ( $tables, $error ) = TOML::Tiny::from_toml($text);
    die 'the table of the runs does not parse: ' . ( $error =~ s/\s+\z//r ) . "\n" if !defined $tables;
    my ( @runs, %digest );
    for my $name ( sort keys $tables->%* ) {
        die "$name is no table\n" if ref $tables->{$name} ne 'HASH';
        my $run = _run( $name, $tables->{$name} );
        my ( $pathname, $digest ) = $run->@{qw(pathname sha256)};
        die "$name names another digest for the archive of $run->{name}\n"
          if defined $digest{$pathname} && $digest{$pathname} ne $digest;
        $digest{$pathname} = $digest;
        push @runs, $run;
    }
    return \@runs;
}

my $ANNOUNCED = qr/\A(\d+) mutants? in (\d+) files?, (\d+) tests?\z/;

# What a run says it found, before its first test starts.
sub announced ($lines) {
    my ($line) = grep { $_ =~ $ANNOUNCED } $lines->@*;
    my %count;
    @count{qw(mutants files tests)} = map { 0 + $_ } $line =~ $ANNOUNCED if defined $line;
    return %count ? \%count : undef;
}

# The numbers of test files and assertions in the last summary line that a test harness printed.
sub harness ($output) {
    my @summaries = $output =~ /^Files=(\d+), Tests=(\d+)/mg;
    return @summaries ? { files => 0 + $summaries[-2], tests => 0 + $summaries[-1] } : undef;
}

sub warning_kind ($text) {
    return 'around-the-hook'  if $text =~ /\bloads \S+ around the hook\b/;
    return 'no-stable-output' if $text =~ /\bPerl decompiles the file to no stable text\b/;
    return 'other';
}

# A machine that names no count of its processors gives one processor by default.
my @PROGRESS = (
    qr/\A\z/,
    qr/\A\d+ processors? (?:online|in the affinity of the process|in the quota of the control group|by default)\z/,
    $ANNOUNCED,
    qr/\AThe unmodified run passed: \d+ tests?, \d+ jobs?\z/,
    qr{\A\[\s*\d+/\d+\](?: \d+ [a-z ]+(?:, \d+ [a-z ]+)*)?\z},
);

# A run writes its progress to standard error, and any other line there is a message that nobody planned.
# A run that ends with another status than 0 ends standard error with one line of the tool, as its manual promises.
sub unexpected_lines ( $lines, $exit ) {
    my @lines = $lines->@*;
    pop @lines if $exit != 0 && @lines && $lines[-1] =~ /\Amutation: /;
    return [
        grep {
            my $line = $_;
            !grep { $line =~ $_ } @PROGRESS
        } @lines
    ];
}

sub _mutants_of ( $file, $entry ) {
    my $source = $entry->{source};
    my @starts = (0);
    push @starts, pos $source while $source =~ /\n/g;
    my @lines = split /\n/, $source, -1;
    my @mutants;
    for my $mutant ( $entry->{mutants}->@* ) {
        my ( $start, $end ) = $mutant->{location}->@{qw(start end)};
        my ( $from, $to ) = map { $starts[ $_->{line} - 1 ] + $_->{column} - 1 } $start, $end;
        push @mutants,
          {
            id          => $mutant->{id},
            file        => $file,
            line        => $start->{line},
            column      => $start->{column},
            mutator     => $mutant->{mutatorName},
            description => $mutant->{description},
            status      => $mutant->{testMutation}{status},
            reason      => $mutant->{testMutation}{reason},
            detail      => $mutant->{statusReason},
            original    => substr( $source, $from, $to - $from ),
            replacement => $mutant->{replacement},
            source      => $lines[ $start->{line} - 1 ],
            covered_by  => scalar $mutant->{coveredBy}->@*,
            killed_by   => $mutant->{killedBy} ? $mutant->{killedBy}[0] : undef,
          };
    }
    return @mutants;
}

sub _in_order (@mutants) {
    my @ordered = sort {
        $a->{file} cmp $b->{file} || $a->{line} <=> $b->{line} || $a->{column} <=> $b->{column} || $a->{id} cmp $b->{id}
    } @mutants;
    return @ordered;
}

# The part of a report of the tool that a record keeps: the facts of the run and each mutant with the text it replaces.
# The sources stay behind, so a record holds one line of foreign code for a mutant and no file.
# A mutant keeps its status in the run and its reason, which the report file holds beside the name of the schema.
sub report ($document) {
    my $facts = $document->{testMutation};
    my $files = $document->{files};
    return {
        jobs              => $facts->{jobs},
        shard             => $facts->{shard},
        warnings          => [ $facts->{warnings}->@* ],
        skipped           => [ map { "$_->{path}: $_->{problem}" } $facts->{problems}->@* ],
        baseline_failures => [ $facts->{baselineFailures}->@* ],
        tests             => scalar $facts->{tests}->@*,
        mutants           => [ _in_order( map { _mutants_of( $_, $files->{$_} ) } keys $files->%* ) ],
    };
}

# The score counts the mutants that a test could have detected, as the documentation of the tool defines it.
sub tally ($mutants) {
    my %counts;
    $counts{ $_->{status} }++ for $mutants->@*;
    my ( $killed, @others ) = map { $counts{$_} || 0 } qw(Killed Survived NoCoverage);
    my $valid = List::Util::sum0( $killed, @others );
    return { counts => \%counts, total => scalar $mutants->@*, score => $valid ? 100 * $killed / $valid : undef };
}

# Some mutants of one status for a reader: one of each mutator, then a second one of each, in the order of the source.
sub sample ( $mutants, $status, $count ) {
    my ( %queue, @mutators );
    for my $mutant ( _in_order( grep { $_->{status} eq $status } $mutants->@* ) ) {
        push @mutators,                        $mutant->{mutator} if !$queue{ $mutant->{mutator} };
        push $queue{ $mutant->{mutator} }->@*, $mutant;
    }
    my @sample;
    while ( $count > @sample && grep { $queue{$_}->@* } @mutators ) {
        push @sample, map { shift $queue{$_}->@* } grep { $queue{$_}->@* } @mutators;
    }
    splice @sample, $count if @sample > $count;
    return \@sample;
}

# The records that the program inside the container printed, one JSON document on each line.
sub records ($text) {
    my ( %records, $number );
    for my $line ( split /\n/, $text ) {
        $number++;
        my $record = eval { JSON::PP->new->utf8->decode($line) };
        die "line $number is no record\n"                   if ref $record ne 'HASH' || !defined $record->{run};
        die "line $number repeats the run $record->{run}\n" if $records{ $record->{run} };
        $records{ $record->{run} } = $record;
    }
    return \%records;
}

sub _inside ( $band, $value ) {
    return defined $value && $band->[0] <= $value && $value <= $band->[1] ? 1 : 0;
}

# The exit status that the documentation of the tool promises for a report.
sub _promised_exit ( $report, $tally ) {
    return 3 if $report->{baseline_failures}->@*;
    my $counts = $tally->{counts};
    return 4 if $counts->{NoVerdict};
    return 4 if $tally->{total} - ( $counts->{Ignored} || 0 ) > 0 && !defined $tally->{score};
    return 0;
}

sub _seen ( $run, $record ) {
    my $report = $record->{report};
    my $tally  = tally( $report ? $report->{mutants} : [] );
    my %warned = map { warning_kind($_) => 1 } $report ? $report->{warnings}->@* : ();
    delete @warned{ $run->{expect}{warnings}->@* };
    return {
        report    => $report,
        counts    => $tally->{counts},
        score     => $tally->{score},
        warned    => \%warned,
        announced => announced( $record->{mutation}{stderr} ) || {},
        passes    => $record->{tests}{exit} == 0                 ? 1                                 : 0,
        stopped   => $report && $report->{baseline_failures}->@* ? 1                                 : 0,
        exit      => $report                                     ? _promised_exit( $report, $tally ) : undef,
    };
}

my $NO_RECORD = 'the run has no record';

# The megabytes that a run may hold at its peak, fourteen times what the largest honest run of the table held.
# A run beyond them keeps something without a limit, such as what a looping test prints.
my $SCRATCH_LIMIT = 256;

# Every kind of finding, with the question that an observation outside the expectation answers with yes.
# The text of a kind is fixed, so a finding names the run and the kind and nothing that changes from run to run.
my @INVARIANTS = (
    [ 'the record belongs to another archive', sub ( $run, $record, $seen ) { $record->{sha256} ne $run->{sha256} } ],
    [
        'the record uses another Perl hash traversal',
        sub ( $run, $record, $seen ) {
            return if !defined $run->{hash_seed};
            my $environment = $record->{environment} || {};
            my ( $seed, $mode ) = $environment->@{qw(PERL_HASH_SEED PERL_PERTURB_KEYS)};
            return !defined $seed || $seed ne $run->{hash_seed} || !defined $mode || $mode ne '0';
        }
    ],
    [ 'the tests of the distribution fail without the tool', sub ( $run, $record, $seen ) { !$seen->{passes} } ],
    [
        'the unmodified run fails where the tests of the distribution pass',
        sub ( $run, $record, $seen ) { $seen->{passes} && $seen->{stopped} }
    ],
    [
        'the unmodified run passes where the tests of the distribution fail',
        sub ( $run, $record, $seen ) { !$seen->{passes} && $seen->{report} && !$seen->{stopped} }
    ],
    [ 'the run ends at the time limit of the harness', sub ( $run, $record, $seen ) { $record->{mutation}{limit} } ],
    [ 'the run leaves no report',                      sub ( $run, $record, $seen ) { !$seen->{report} } ],
    [
        'the run fills its scratch space',
        sub ( $run, $record, $seen ) { ( $record->{mutation}{scratch} || 0 ) > $SCRATCH_LIMIT }
    ],
    [
        'the exit status disagrees with the report',
        sub ( $run, $record, $seen ) { $seen->{report} && $record->{mutation}{exit} != $seen->{exit} }
    ],
    [
        'the run reports a mutant that fails to compile', sub ( $run, $record, $seen ) { $seen->{counts}{CompileError} }
    ],
    [ 'the run reports a mutant without a verdict', sub ( $run, $record, $seen ) { $seen->{counts}{NoVerdict} } ],
    [ 'the run leaves a mutant pending',            sub ( $run, $record, $seen ) { $seen->{counts}{Pending} } ],
    [
        'the run warns that a test loads a source around the hook',
        sub ( $run, $record, $seen ) { $seen->{warned}{'around-the-hook'} }
    ],
    [
        'the run warns that B::Deparse gives no stable output',
        sub ( $run, $record, $seen ) { $seen->{warned}{'no-stable-output'} }
    ],
    [ 'the run gives a warning of another kind', sub ( $run, $record, $seen ) { $seen->{warned}{other} } ],
    [ 'the run skips a source file', sub ( $run, $record, $seen ) { $seen->{report} && $seen->{report}{skipped}->@* } ],
    [
        'the run writes an unexpected line to standard error',
        sub ( $run, $record, $seen ) { unexpected_lines( $record->{mutation}{stderr}, $record->{mutation}{exit} )->@* }
    ],
    [
        'the number of mutants lies outside its band',
        sub ( $run, $record, $seen ) { !_inside( $run->{expect}{mutants}, $seen->{announced}{mutants} ) }
    ],
    [
        'the score lies outside its band',
        sub ( $run, $record, $seen ) { $run->{expect}{score} && !_inside( $run->{expect}{score}, $seen->{score} ) }
    ],
    [
        'the run gives a score, and the table states no band for it',
        sub ( $run, $record, $seen ) { !$run->{expect}{score} && defined $seen->{score} }
    ],
    [
        'the run finds another number of test files than prove',
        sub ( $run, $record, $seen ) {
            my ( $found, $proved ) = ( $seen->{announced}{tests}, $record->{prove}{files} );

            # A configuration of the run may choose the test files, and then the two numbers answer two questions.
            return !defined $run->{config} && defined $found && defined $proved && $found != $proved;
        }
    ],
);

sub kinds () {
    return ( $NO_RECORD, map { $_->[0] } @INVARIANTS );
}

# The findings of one run: its name and the kind of each expectation that the record breaks.
sub findings ( $run, $record ) {
    return ["$run->{run}: $NO_RECORD"] if !$record;
    my $seen = _seen( $run, $record );
    return [ map { "$run->{run}: $_->[0]" } grep { $_->[1]->( $run, $record, $seen ) } @INVARIANTS ];
}

# The findings of every run of the table, and one for each record that names no run of it.
sub judged ( $runs, $records ) {
    my %run = map { $_->{run} => 1 } $runs->@*;
    return [
        ( map { findings( $_, $records->{ $_->{run} } )->@* } $runs->@* ),
        ( map { "$_: the table has no run for the record" } sort grep { !$run{$_} } keys $records->%* ),
    ];
}

# What a reader wants beside the findings and what decides nothing: the time, and a plain prove that disagrees.
sub notes ( $run, $record ) {
    my @notes;
    my ( $took, $allowed ) = ( $record->{mutation}{seconds}, $run->{expect}{seconds} );
    push @notes, sprintf 'the run took %.0f s, over the %d s of the table', $took, $allowed if $took > $allowed;
    my ( $proved, $passed ) = map { $record->{$_}{exit} == 0 ? 1 : 0 } qw(prove tests);
    push @notes, 'prove -lr t fails where the tests of the table pass'  if $passed  && !$proved;
    push @notes, 'prove -lr t passes where the tests of the table fail' if !$passed && $proved;
    return \@notes;
}

# One line about a run for the output of the gate.
sub summary ($record) {
    my $report = $record->{report};
    my $tally  = tally( $report ? $report->{mutants} : [] );
    my $counts = join ', ', map { "$tally->{counts}{$_} $_" } sort keys $tally->{counts}->%*;
    my $found  = announced( $record->{mutation}{stderr} );
    return join '; ',
      "exit $record->{mutation}{exit}",
      ( $found                  ? "$found->{mutants} mutants, $found->{tests} tests" : 'nothing announced' ),
      ( length $counts          ? $counts                                            : 'no mutant with a status' ),
      ( defined $tally->{score} ? sprintf 'score %.1f', $tally->{score}              : 'no score' ),
      sprintf( '%.0f s', $record->{mutation}{seconds} ),
      sprintf '%d MB', $record->{mutation}{scratch} || 0;
}

1;
