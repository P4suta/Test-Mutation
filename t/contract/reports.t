use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Encode   ();
use JSON::PP ();
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Html;
use Test::Mutation::Report::Json;
use Test::Mutation::Report::Terminal;
use Test::Mutation::Runner;
use Test::Mutation::Status;

# S6, the reports: results of every outcome, with each status present and absent, in every shape of source and every format.
# Every format states the same counts, the report file reads back as it was written, and its score is the score of the run.

my @statuses  = Test::Mutation::Status::rows()->@*;
my %status_of = map { $_->word => $_->name } @statuses;
my $format    = Samples::type('format');
my @formats   = sort $format->{valid}->@*;
my @sets      = Space::result_sets()->@*;
my @shapes    = Space::shapes()->@*;
my $failure   = [ { test => 't/sample.t', output => "not ok 1\n", errors => q{} } ];
my %violations;

sub violation ( $gate, $what, $one, $format ) {
    push $violations{$gate}->@*, [ $what, $one, $format ];
    return;
}

sub tallied (@names) {
    my %count;
    $count{$_}++ for @names;
    return \%count;
}

sub mutants_of ($document) {
    return map { $_->{mutants}->@* } values $document->{files}->%*;
}

# The counts of the statuses of the run, which a report file keeps beside the name of the schema.
sub document_counts ($document) {
    return tallied( map { $_->{testMutation}{status} } mutants_of($document) );
}

# The documents of the report files, as a viewer reads them.
my %document_of = (
    json => sub ($result) {
        return JSON::PP->new->decode( Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ) );
    },
    html => sub ($result) {
        my ($data) =
          Test::Mutation::Report::Html::render( $result, high => 80, low => 60 ) =~
          m{<script id="report" type="application/json">(.*?)</script>}s
          or die "the HTML report holds no document\n";
        return JSON::PP->new->decode($data);
    },
);

# The counts that each format states, by status, or nothing for a report without counts.
my %stated = (
    terminal => sub ($result) {
        my ($summary) = Test::Mutation::Report::Terminal::render( $result, color => 0 ) =~ /\A\d+ mutants?(:[^\n]*)?\n/
          or return;
        return { map { /(\d+) (.+)\z/ ? ( $status_of{$2} => $1 ) : () } split /, /, defined $summary ? $summary : q{} };
    },
    json   => sub ($result) { return document_counts( $document_of{json}->($result) ) },
    html   => sub ($result) { return document_counts( $document_of{html}->($result) ) },
    github => sub ($result) {
        my ( $heads, $values ) = ( split /\n/, Test::Mutation::Report::GitHub::summary($result) )[ -3, -1 ];
        my @heads  = map  { $status_of{ lc $_ } } grep { length } split /\s*[|]\s*/, $heads;
        my @values = grep { length } split /\s*[|]\s*/, $values;
        return { map { $heads[$_] => $values[$_] } 0 .. $#heads };
    },
);

sub facts ($result) {
    return [ map { { id => $_->{mutant}->id, $_->%{qw(status reason detail)} } } $result->entries->@* ];
}

# The report file as the command writes it and as the merge reads it: UTF-8 on the way out and on the way in.
sub read_again ($result) {
    my $bytes = Encode::encode( 'UTF-8', Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ) );
    return Test::Mutation::Report::Json::parse( Encode::decode( 'UTF-8', $bytes ) );
}

subtest 'the readers of the reports reject a count that a format leaves out' => sub {
    my $result = Samples::result( statuses => [qw(Killed Killed Timeout Ignored)] );
    my %counts = ( Killed => 2, Timeout => 1, Ignored => 1 );
    is $stated{$_}->($result), \%counts, "the counts of the $_ report" for qw(terminal json html);
    is $stated{github}->($result), { ( map { $_->name => 0 } @statuses ), %counts }, 'the counts of the summary';
    is [ Invariants::counts( \%counts, { Killed => 2, Timeout => 1 } ) ],
      [ [ 'the report states no count', 'Ignored' ] ],
      'a report that leaves a status out';
    is tallied( map { $_->{status} } mutants_of( $document_of{json}->($result) ) ), { Killed => 2, Ignored => 2 },
      'the report file writes the names of the schema, which a viewer counts';
    is [ Invariants::round_trip( facts($result), facts( read_again($result) ) ) ], [], 'the report file reads back';
};

my $count = 0;
my %seen;
for my $shape (@shapes) {
    for my $case ( ( map { ( [ $_->@*, undef ], [ $_->@*, 'INT' ] ) } @sets ), [ 'failing', [], undef ] ) {
        my ( $label, $names, $signal ) = $case->@*;
        my $failing = $label eq 'failing';
        my $result  = Samples::result(
            statuses    => $names,
            interrupted => $signal,
            letters     => $shape->{letters},
            lines       => $shape->{lines},
            ( $failing ? ( baseline_failures => $failure ) : () ),
        );
        my $counts = tallied( $names->@* );
        for my $format (@formats) {
            $count++;
            $seen{format}{$format} = $seen{shape}{ $shape->{label} } = $seen{set}{$label} = 1;
            my $stated = $stated{$format}->($result) or next;
            violation( 'counts', $_->[0], $_->[1], $format ) for Invariants::counts( $counts, $stated );
        }

        # A viewer of the report file computes the score from the statuses that the file holds.
        for my $format ( sort keys %document_of ) {
            my $held = tallied( map { $_->{status} } mutants_of( $document_of{$format}->($result) ) );
            violation( 'role', $_, $label, $format ) for Invariants::role( $held, $result->tally->{score} );
        }
        my $again = read_again($result);
        my @lost  = Invariants::round_trip( facts($result), facts($again) );

        # The report file holds the sources of its mutants, so a source without a mutant has no place in it.
        my %held = $names->@* ? $result->sources->%* : ();
        push @lost, 'the text of a source changes' if Space::differences( \%held, $again->sources )->@*;
        push @lost, 'the signal of the run changes'
          if ( defined $signal ? $signal : 'none' ) ne ( defined $again->interrupted ? $again->interrupted : 'none' );
        violation( 'round-trip', $_, $shape->{label}, 'json' ) for @lost;
    }
}

is $count,       @shapes * @formats * ( 2 * @sets + 1 ), 'every result in every shape and every format';
is scalar @sets, 2 + 2 * @statuses,                      'no status, every status, and each status alone and left out';
is [ sort keys $seen{format}->%* ], \@formats,                            'every format of the settings table';
is [ sort keys $seen{shape}->%* ],  [ sort map { $_->{label} } @shapes ], 'every shape';
Gate::checked( 'reports', $count, at_least => 800 );

subtest 'the bytes of the terminal report through the command' => sub {
    for my $shape (@shapes) {
        my $result =
          Samples::result( statuses => [qw(Survived Killed)], letters => $shape->{letters}, lines => $shape->{lines} );
        my $report = Test::Mutation::Report::Terminal::render( $result, color => 0 );
        no warnings 'redefine';
        local *Test::Mutation::Runner::run = sub { return $result };
        my $observation = World::observe( [ 'run', '--format', 'terminal' ], cwd => Space::scratch() );
        is $observation->{exit}, 0, "the run of $shape->{label} succeeds";
        violation( 'stdout', $_, $shape->{label}, 'terminal' )
          for Invariants::encoded( $observation->{stdout}, $report );
        violation( 'no-leak', $_, $shape->{label}, 'terminal' ) for Invariants::no_leak($observation);
    }
    Gate::checked( 'shapes through the command', scalar @shapes, at_least => 6 );
};

Gate::findings( 'contract-counts-reports',     Space::folded( $violations{counts} || [], 'statuses',     'formats' ) );
Gate::findings( 'contract-role-reports',       Space::folded( $violations{role}   || [], 'results',      'formats' ) );
Gate::findings( 'contract-round-trip-reports', Space::folded( $violations{'round-trip'} || [], 'shapes', 'formats' ) );
Gate::findings( 'contract-stdout-reports',     Space::folded( $violations{stdout}       || [], 'shapes', 'formats' ) );
Gate::findings( 'contract-no-leak-reports',    Space::folded( $violations{'no-leak'}    || [], 'shapes', 'formats' ) );

done_testing;
