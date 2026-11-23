package Permutl::Report::Json;
use v5.36;
use JSON::PP               ();
use Types::Standard        qw(ArrayRef Dict HashRef InstanceOf Int Maybe Num Optional Slurpy Str Tuple);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);
use Permutl::Mutant;
use Permutl::Result;
use Permutl::Source;

our $VERSION = '0.001';

my $MILLISECONDS = 1000;

signature_for document => (
    head    => [ InstanceOf ['Permutl::Result'] ],
    named   => [ high => Num, low => Num ],
    returns => HashRef,
);

sub document ( $result, $arg ) {
    my %files;
    for my $entry ( $result->entries->@* ) {
        my $path = $entry->{mutant}->path;
        $files{$path} = { language => 'perl', source => $result->sources->{$path}, mutants => [] } if !$files{$path};
        push $files{$path}{mutants}->@*, _mutant($entry);
    }
    return {
        schemaVersion => '2',
        thresholds    => { high => int( $arg->high + 0.5 ), low => int( $arg->low + 0.5 ) },
        projectRoot   => $result->root,
        framework     => { name => 'permutl', version => $VERSION },
        files         => \%files,
        testFiles     =>
          { map { $_->{name} => { tests => [ { id => $_->{name}, name => $_->{name} } ] } } $result->tests->@* },
        permutl => _facts($result),
    };
}

sub _boolean ($value) {
    return $value ? JSON::PP::true : JSON::PP::false;
}

# The schema has no place for these facts, and a merge of several reports needs them.
sub _facts ($result) {
    my $inventory = $result->inventory;
    return {
        shard        => $result->shard,
        inventory    => $inventory ? { mutants => $inventory->{mutants} + 0, digest => $inventory->{digest} } : undef,
        jobs         => $result->jobs + 0,
        parallelSafe => _boolean( $result->parallel_safe ),
        interrupted  => $result->interrupted,
        reused       => $result->reused + 0,
        started      => $result->started + 0,
        finished     => $result->finished + 0,
        warnings     => [ $result->warnings->@* ],
        problems     => [ map { { path => $_->{path}, problem => $_->{problem} } } $result->problems->@* ],
        baselineFailures => [ map { $_->{test} } $result->baseline_failures->@* ],
        tests            => [ map { { name => $_->{name}, duration => $_->{duration} + 0 } } $result->tests->@* ],
    };
}

sub _mutant ($entry) {
    my $mutant = $entry->{mutant};
    my %mutant = (
        id             => $mutant->id,
        mutatorName    => $mutant->mutator,
        replacement    => $mutant->replacement,
        description    => $mutant->description,
        location       => { start => _position( $mutant->from ), end => _position( $mutant->to ) },
        status         => $entry->{status},
        coveredBy      => [ $entry->{covered_by}->@* ],
        testsCompleted => $entry->{tests_run} + 0,
        duration       => int( $entry->{duration} * $MILLISECONDS + 0.5 ),
        static         => JSON::PP::false,
        permutl        => {
            scope      => [ map { $_ + 0 } $mutant->scope->@* ],
            suppressed => _boolean( $mutant->suppressed ),
            comparable => _boolean( $mutant->comparable ),
        },
    );
    $mutant{statusReason} = $entry->{reason} if defined $entry->{reason};
    $mutant{killedBy}     = [ $entry->{by} ] if $entry->{status} eq 'Killed' && defined $entry->{by};
    return \%mutant;
}

sub _position ($pair) {
    return { line => $pair->[0] + 0, column => $pair->[1] + 0 };
}

signature_for render => (
    head    => [ InstanceOf ['Permutl::Result'] ],
    named   => [ high => Num, low => Num ],
    returns => Str,
);

sub render ( $result, $arg ) {
    my $document = document( $result, high => $arg->high, low => $arg->low );
    return JSON::PP->new->canonical->pretty->encode($document);
}

my $FLAG     = InstanceOf ['JSON::PP::Boolean'];
my $POSITION = Dict [ line => PositiveInt, column => PositiveInt ];
my $MUTANT   = Dict [
    id             => Str,
    mutatorName    => Str,
    replacement    => Str,
    description    => Str,
    location       => Dict [ start => $POSITION, end => $POSITION ],
    status         => Str,
    statusReason   => Optional [Str],
    coveredBy      => ArrayRef [Str],
    killedBy       => Optional [ ArrayRef [Str] ],
    testsCompleted => Int,
    duration       => Num,
    static         => $FLAG,
    permutl        => Dict [ scope => Tuple [ Int, Int ], suppressed => $FLAG, comparable => $FLAG ],
];
my $DOCUMENT = Dict [
    projectRoot => Str,
    files       => HashRef [ Dict [ language => Str, source => Str, mutants => ArrayRef [$MUTANT] ] ],
    permutl     => Dict [
        shard            => Maybe [Str],
        inventory        => Maybe [ Dict [ mutants => Int, digest => Str ] ],
        jobs             => Int,
        parallelSafe     => $FLAG,
        interrupted      => Maybe [Str],
        reused           => Int,
        started          => Num,
        finished         => Num,
        warnings         => ArrayRef [Str],
        problems         => ArrayRef [ Dict [ path => Str, problem => Str ] ],
        baselineFailures => ArrayRef [Str],
        tests            => ArrayRef [ Dict [ name => Str, duration => Num ] ],
    ],
    Slurpy [HashRef],
];

signature_for parse => ( positional => [Str], returns => InstanceOf ['Permutl::Result'] );

sub parse ($text) {
    my $document = eval { JSON::PP->new->decode($text) };
    die "the text is no JSON document\n"             if ref $document ne 'HASH';
    die "the report holds no run facts of permutl\n" if !exists $document->{permutl};
    my $problem = $DOCUMENT->validate_explain( $document, 'the report' );
    die 'the report is malformed: ' . ( grep { /did not pass|constrains/ } reverse $problem->@* )[0] . "\n" if $problem;
    my $result = eval { _result($document) };
    return $result if $result;
    my ($reason) = split /\n/, "$@";
    die 'the report is malformed: ' . $reason =~ s/ at \S+ line \d+[.]?\z//r . "\n";
}

sub _result ($document) {
    my $facts = $document->{permutl};
    my ( %sources, @entries );
    for my $path ( sort keys $document->{files}->%* ) {
        my $file = $document->{files}{$path};
        $sources{$path} = $file->{source};
        my $source = Permutl::Source->new( path => $path, text => $file->{source}, encoding => 'UTF-8' );
        push @entries, map { _entry( $source, $_ ) } $file->{mutants}->@*;
    }
    return Permutl::Result->new(
        root              => $document->{projectRoot},
        sources           => \%sources,
        tests             => $facts->{tests},
        entries           => \@entries,
        problems          => $facts->{problems},
        warnings          => $facts->{warnings},
        baseline_failures => [ map { { test => $_, output => q{}, errors => q{} } } $facts->{baselineFailures}->@* ],
        jobs              => $facts->{jobs},
        parallel_safe     => $facts->{parallelSafe} ? 1 : 0,
        interrupted       => $facts->{interrupted},
        reused            => $facts->{reused},
        shard             => $facts->{shard},
        inventory         => $facts->{inventory},
        started           => $facts->{started},
        finished          => $facts->{finished},
    );
}

sub _offset ( $source, $position ) {
    my $text   = $source->text;
    my $offset = $position->{line} <= 1 + $text =~ tr/\n// ? $source->offset_of( $position->@{qw(line column)} ) : -1;
    die 'a location lies outside the source of ' . $source->path . "\n" if $offset < 0 || $offset > length $text;
    return $offset;
}

sub _entry ( $source, $mutant ) {
    my ( $start, $end ) = map { _offset( $source, $mutant->{location}{$_} ) } qw(start end);
    die 'a location ends before its start in ' . $source->path . "\n" if $end < $start;
    my ( $extra, $duration ) = $mutant->@{qw(permutl duration)};
    return {
        mutant => Permutl::Mutant->new(
            id          => $mutant->{id},
            path        => $source->path,
            mutator     => $mutant->{mutatorName},
            start       => $start,
            end         => $end,
            original    => substr( $source->text, $start, $end - $start ),
            replacement => $mutant->{replacement},
            description => $mutant->{description},
            from        => [ $mutant->{location}{start}->@{qw(line column)} ],
            to          => [ $mutant->{location}{end}->@{qw(line column)} ],
            scope       => $extra->{scope},
            suppressed  => $extra->{suppressed} ? 1 : 0,
            comparable  => $extra->{comparable} ? 1 : 0,
        ),
        status     => $mutant->{status},
        reason     => $mutant->{statusReason},
        by         => $mutant->{killedBy} ? $mutant->{killedBy}[0] : undef,
        covered_by => $mutant->{coveredBy},
        tests_run  => $mutant->{testsCompleted},
        duration   => $duration / $MILLISECONDS,
    };
}

1;

__END__

=head1 NAME

Permutl::Report::Json - render a result in the mutation testing report schema

=head1 SYNOPSIS

    my $text = Permutl::Report::Json::render( $result, high => 80, low => 60 );

=head1 DESCRIPTION

The report follows version 2 of the C<mutation-testing-report-schema> that the Stryker projects publish.
Tools that read that schema, such as the C<mutation-testing-elements> viewer, can display it.

=head1 FUNCTIONS

=head2 document

Returns the report as a data structure.
Each test file appears as one test, because permutl runs test files as units.
The C<permutl> key of the document and of each mutant holds the facts that the schema has no place for.
The schema allows such keys, and C<permutl merge> reads them.

=head2 render

Returns the report as JSON text with sorted keys.

=head2 parse

    my $result = Permutl::Report::Json::parse($text);

Rebuilds the L<Permutl::Result> that a report describes.
The spans and the original text of the mutants come from the sources in the report.
The rebuilt result holds the sources that have mutants, and it names the failing tests of the unmodified run without their output.
The function dies when the text is no report that permutl wrote.

=cut
