package Invariants;
use v5.36;

# Each invariant reads one observation and returns the symptoms that break it, or nothing.
# A symptom is a fixed phrase and never the text of the tool, so a finding reads the same on every machine.

sub _named ( $text, $name ) {
    return $text =~ /(?<![\w-])\Q$name\E(?![\w-])/ ? 1 : 0;
}

# exit-domain: the exit status is one that the table of exit statuses names.
sub exit_domain ( $observation, $codes ) {
    my $exit = $observation->{exit};
    return ( grep { $_ == $exit } $codes->@* ) ? () : ("status $exit stands in no table");
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
    my %count = ( ( map { $_ => 0 } qw(Timeout RuntimeError Pending) ), $counts->%* );
    my $score = _score( \%count );
    return ( 'interrupted',     $fact{signal} ) if $fact{signal};
    return ( 'baseline-failed', 3 )             if $fact{baseline_failed};
    return ( 'inconclusive', 4 ) if $count{RuntimeError} || $count{Pending} || ( !defined $score && $count{Timeout} );
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

# stdout: standard output holds the report alone, so a refusal prints nothing there and no progress line lands there.
sub stdout ($observation) {
    my $text = $observation->{stdout};
    return 'a refusal prints to standard output' if $observation->{exit} == 2 && length $text;
    return 'a progress line on standard output'  if $text =~ /^\[\s*\d+\/\d+\]|^The unmodified run passed|^mutation: /m;
    return 'the report of the run on standard error' if $observation->{stderr} =~ /^Score: |^\d+ mutants?: /m;
    return;
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
