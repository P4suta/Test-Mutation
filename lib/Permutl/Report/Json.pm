package Permutl::Report::Json;
use v5.36;
use JSON::PP        ();
use Types::Standard qw(HashRef InstanceOf Num Str);
use Type::Params    qw(signature_for);

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

=head2 render

Returns the report as JSON text with sorted keys, encoded as UTF-8.

=cut
