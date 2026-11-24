package Invariants;
use v5.36;
use Encode ();

# Each invariant reads one observation and returns the symptoms that break it, or nothing.
# A symptom is a fixed phrase and never the text of the tool, so a finding reads the same on every machine.

sub _named ( $text, $name ) {
    return $text =~ /(?<![\w-])\Q$name\E(?![\w-])/ ? 1 : 0;
}

my $INTERNAL = 6;

# exit-domain: the exit status is one that the table of exit statuses names, and never the one of an internal error.
sub exit_domain ( $observation, $codes ) {
    my $exit = $observation->{exit};
    return ("status $exit stands in no table") if !grep { $_ == $exit } $codes->@*;
    return $exit == $INTERNAL ? ("status $exit states a defect of the tool") : ();
}

# exit-table: the exit status is the one that the kind of the error or the outcome calls for.
sub exit_table ( $observation, $expected ) {
    my $exit = $observation->{exit};
    return $exit == $expected ? () : ("status $exit, where the table calls for $expected");
}

# one-line: a status other than zero ends standard error with exactly one line that starts with the name of the command.
sub one_line ($observation) {
    return if !$observation->{exit};
    my @lines    = split /\n/, $observation->{stderr};
    my @prefixed = grep { /\Amutation: / } @lines;
    return 'no line with the prefix'             if !@prefixed;
    return 'several lines with the prefix'       if @prefixed > 1;
    return 'text after the line with the prefix' if $lines[-1] !~ /\Amutation: /;
    return 'other lines before the refusal'      if $observation->{exit} == 2 && @lines > 1;
    return;
}

my @LEAKS = (
    [ 'a place in the source'       => qr/ at \S+ line \d+/ ],
    [ 'a package name'              => qr/\b[[:upper:]]\w*(?:::\w+)+/ ],
    [ 'a variable of the code'      => qr/\$\w+(?:->)?\{/ ],
    [ 'wording of the type library' => qr/type constraint|did not pass|Must be an? / ],
    [
        'wording of the option parser' =>
          qr/^(?:Unknown option: |Option \S+ (?:requires|does not take|is ambiguous)|Value ".*" invalid for option )/m
    ],
);

# no-leak: the output shows nothing of the code that produced it.
sub no_leak ($observation) {
    my $text = $observation->{stderr};
    return (
        ( map { $_->[0] } grep { $text =~ $_->[1] } @LEAKS ),
        ( $observation->{warnings}->@* ? 'a warning of Perl' : () )
    );
}

# typed-name: an error names the spelling that the user typed, and never the name of another surface.
sub typed_name ( $observation, $typed, $attribute = undef ) {
    my $text  = $observation->{stderr};
    my $other = defined $attribute && $attribute ne $typed =~ s/\A-+//r;
    return (
        ( _named( $text, $typed )               ? () : 'the message lacks the spelling that the user typed' ),
        ( $other && _named( $text, $attribute ) ? 'the message names the attribute' : () ),
    );
}

# unknown: the refusal of an unknown name shows the nearest name that exists.
sub nearest ( $observation, $nearest ) {
    return _named( $observation->{stderr}, $nearest ) ? () : ('the refusal names no nearest name');
}

# one-name: the flag, the key, and the attribute of a setting are one name.
sub one_name ($setting) {
    my ( $section, $key ) = $setting->key ? $setting->key->@* : ();
    my @spelled = (
        ( defined $setting->flag      ? $setting->flag                                 : () ),
        ( defined $key                ? ( length $section ? "[$section] $key" : $key ) : () ),
        ( defined $setting->attribute ? $setting->attribute                            : () ),
    );
    my %name = map { s/\A(?:--|\[\w+\] )//r =~ tr/-/_/r => 1 } @spelled;
    return keys %name > 1 ? ( join ', ', @spelled ) : ();
}

# all-surfaces: every setting is on the command line, in the configuration file, and in the library.
sub all_surfaces ($setting) {
    return (
        ( defined $setting->flag      ? () : 'flag' ),
        ( $setting->key               ? () : 'file' ),
        ( defined $setting->attribute ? () : 'library' ),
    );
}

# same-config: every surface answers one sample alike, with the value of the sample or with a refusal.
# An answer is nothing for a refusal, and the text of the value otherwise.
sub same_config ( $expect, $sample, $answer ) {
    return defined $answer ? 'an invalid sample: accepted' : () if $expect eq 'invalid';
    return 'a valid sample: refused'                            if !defined $answer;
    return $answer eq $sample ? () : 'a valid sample: another value';
}

# selector: a selector that the user wrote and that selects nothing is a usage error that names it.
sub selector ( $observation, $expected, $named ) {
    my $exit = $observation->{exit};
    return "status $exit, where the selector calls for $expected" if $exit != $expected;
    return                                                        if $expected != 2 || !length $named;
    return _named( $observation->{stderr}, $named ) ? () : 'the refusal lacks the selector';
}

# no-effect: a usage error copies no project and starts no test.
sub no_effect ($started) {
    return (
        ( $started->{copies} ? 'the project was copied before the refusal' : () ),
        ( $started->{tests}  ? 'a test started before the refusal'         : () ),
    );
}

# The outcome of a run and the exit status that it calls for, from the facts of the result alone.
# `counts` maps each status to its count, `gate` is the score that the user asks for or nothing, and `part` is true for one part of a split run.
sub outcome ( $counts, %fact ) {
    my %count = ( ( map { $_ => 0 } qw(Timeout NoVerdict Pending) ), $counts->%* );
    my $score = _score( \%count );
    return ( 'interrupted',     $fact{signal} ) if $fact{signal};
    return ( 'baseline-failed', 3 )             if $fact{baseline_failed};
    return ( 'inconclusive',    4 ) if $count{NoVerdict} || $count{Pending} || ( !defined $score && $count{Timeout} );
    my $gated = defined $fact{gate} && !$fact{part};
    return ( 'nothing', $gated ? 4 : 0 ) if !defined $score;
    my $below = $gated && $score < $fact{gate};
    return ( 'measured', $below ? 1 : 0 );
}

# The percentage of the detected mutants among the valid ones, or nothing without a valid mutant.
sub _score ($count) {
    my $killed = $count->{Killed} || 0;
    my $valid  = $killed + ( $count->{Survived} || 0 ) + ( $count->{NoCoverage} || 0 );
    return if !$valid;
    my $share = $killed / $valid;
    return 100 * $share;
}

# gate: success under a gate means a score that meets it, or a narrowed selection that is empty.
# `exits` maps each gate to the exit status under it.
sub gate ( $counts, $part, $exits ) {
    my $score = _score($counts);
    my @gates = sort { $a <=> $b } keys $exits->%*;
    my @symptoms;
    for my $gate ( grep { $exits->{$_} == 0 } @gates ) {
        push @symptoms, 'success without a score'       if !defined $score && !$part;
        push @symptoms, 'success with a score below it' if defined $score  && $score < $gate;
    }
    for my $index ( 1 .. $#gates ) {
        push @symptoms, 'a higher gate turns a failure into success'
          if $exits->{ $gates[ $index - 1 ] } != 0 && $exits->{ $gates[$index] } == 0;
    }
    my %seen;
    return grep { !$seen{$_}++ } @symptoms;
}

# three-deciders: `run`, `merge` of the split result, and `mutation_score_ok` decide alike.
# Each decision is true for success, and nothing for a decider that the case leaves out.
sub three_deciders (%success) {
    my @deciders = grep { defined $success{$_} } sort keys %success;
    my @passing  = grep { $success{$_} } @deciders;
    return if !@passing || @passing == @deciders;
    return 'pass: ' . join( ', ', @passing ) . '; fail: ' . join ', ', grep { !$success{$_} } @deciders;
}

# independent: one setting changes the effect of another only through a declared interaction.
# Each argument maps the attributes to their texts: with no setting, with each of two settings, and with both.
# The answer names the attributes that the pair sets another way than its two settings do alone.
sub independent ( $base, $one, $other, $both ) {
    return 'the pair is refused' if !$both;
    my @differ;
    for my $name ( sort keys $base->%* ) {
        my $expected = $one->{$name} ne $base->{$name} ? $one->{$name} : $other->{$name};
        push @differ, $name if $both->{$name} ne $expected;
    }
    return @differ;
}

# round-trip: a report that is written and read again keeps every status, every reason, and every sentence about a case.
# Each side lists the identifier, the status, the reason, and the detail of its mutants.
sub round_trip ( $written, $read ) {
    my %read = map { $_->{id} => $_ } $read->@*;
    my %symptom;
    for my $fact ( $written->@* ) {
        my $again = $read{ $fact->{id} };
        if ( !$again ) {
            $symptom{'a mutant is gone'} = 1;
            next;
        }
        $symptom{'a status changes'} = 1 if $again->{status} ne $fact->{status};
        for my $field (qw(reason detail)) {
            my ( $before, $after ) = map { defined $_->{$field} ? "$field $_->{$field}" : 'none' } $fact, $again;
            $symptom{"a $field changes"} = 1 if $before ne $after;
        }
    }
    my @symptoms = sort keys %symptom;
    return @symptoms;
}

# role: the score equals the one that the formula of the report schema gives for the statuses of the report.
# A viewer of the report computes its score that way: a timeout counts as detected.
# `counts` maps each status that the report file writes, the name of the schema, to its count.
sub role ( $counts, $score ) {
    my %count    = ( ( map { $_ => 0 } qw(Killed Timeout Survived NoCoverage) ), $counts->%* );
    my $detected = $count{Killed} + $count{Timeout};
    my $valid    = $detected + $count{Survived} + $count{NoCoverage};
    my $share    = $valid ? $detected / $valid : undef;
    my ( $theirs, $ours ) = map { defined $_ ? sprintf '%.6f', $_ : 'none' } ( defined $share ? 100 * $share : undef ),
      $score;
    return $theirs eq $ours ? () : ('the score differs from the formula of the report schema');
}

# counts: a report states the count of the result for every status that the result holds.
# The answer pairs each symptom with its status.
sub counts ( $expected, $stated ) {
    return map {
            !exists $stated->{$_}            ? [ 'the report states no count',      $_ ]
          : $stated->{$_} != $expected->{$_} ? [ 'the report states another count', $_ ]
          : ()
    } grep { $expected->{$_} } sort keys $expected->%*;
}

sub _progress_line ($line) {
    my ( $position, $total, $rest ) = $line =~ /\A\[\s*(\d+)\/(\d+)\](.*)\z/ or return;
    my %stated = map { /\A(\d+) (.+)\z/ ? ( $2 => $1 ) : () } split /, /, $rest =~ s/\A //r;
    return { position => $position, total => $total, stated => \%stated };
}

# progress-sum: the counts of a progress line sum to its position.
sub progress_sum ($lines) {
    my %symptom;
    for my $line ( grep { defined } map { _progress_line($_) } $lines->@* ) {
        my $sum = 0;
        $sum += $_ for values $line->{stated}->%*;
        $symptom{'the counts of a line sum to less than its position'} = 1 if $sum < $line->{position};
        $symptom{'the counts of a line sum to more than its position'} = 1 if $sum > $line->{position};
    }
    my @symptoms = sort keys %symptom;
    return @symptoms;
}

# progress-final: the last progress line states the tally of the result.
# `words` maps each status to the word that counts it, and the answer names the statuses that the last line gets wrong.
sub progress_final ( $lines, $counts, $words ) {
    my @parsed = grep { defined } map { _progress_line($_) } $lines->@*;
    my $last   = @parsed ? $parsed[-1] : { position => 0, total => 0, stated => {} };
    my $ended  = $last->{position} == $last->{total};
    return grep {
        my $stated = $last->{stated}{ $words->{$_} };
        !$ended || !defined $stated || $stated != $counts->{$_}
    } grep { $counts->{$_} } sort keys $counts->%*;
}

# liveness: the progress never stays silent for longer than a fixed time.
# Each argument is the longest silence of a run in steps of its work, for a small run and for a large one.
sub liveness ( $small, $large ) {
    return $large > $small ? ('the silence grows with the run') : ();
}

# message: some case produces every message that a user may read.
# A message holds a mark where the code puts a value, and a text may carry the message behind the words of its sender.
# The answer lists the messages that no text carries.
sub message ( $messages, $texts ) {
    my @heard;
    for my $line ( map { split /\n/ } $texts->@* ) {
        my @parts = split /: /, $line, -1;
        push @heard, map { join ': ', @parts[ $_ .. $#parts ] } 0 .. $#parts;
    }
    return grep {
        my $pattern = join '.*', map { quotemeta } split /\x{2026}/, $_, -1;
        !grep { /\A$pattern\z/ } @heard
    } $messages->@*;
}

# stdout: standard output holds the report alone, so a refusal prints nothing there and no progress line lands there.
sub stdout ($observation) {
    my $text = $observation->{stdout};
    return 'a refusal prints to standard output' if $observation->{exit} == 2 && length $text;
    return 'a progress line on standard output'  if $text =~ /^\[\s*\d+\/\d+\]|^The unmodified run passed|^mutation: /m;
    return 'the report of the run on standard error' if $observation->{stderr} =~ /^Score: |^\d+ mutants?: /m;
    return;
}

# stdout, for the letters of a report: the bytes that the command writes are the UTF-8 form of the text of the report.
sub encoded ( $bytes, $text ) {
    my $read = eval { Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK | Encode::LEAVE_SRC ) };
    return defined $read && $read eq $text ? () : ('the bytes of the output are no UTF-8 form of the report');
}

# help: the word prints its text, succeeds, and leaves standard error empty, wherever it stands.
sub help ( $observation, $text ) {
    my $exit = $observation->{exit};
    return 'the command goes on'    if !defined $exit;
    return "status $exit"           if $exit != 0;
    return 'another text'           if $observation->{stdout} ne $text;
    return 'text on standard error' if length $observation->{stderr};
    return;
}

1;
