use v5.36;
use Test2::V0;
use lib 't/lib';
use Gate;

# A record kind that one side writes and another side drops reads as a test that did nothing.
# The gate holds the kinds that the shim writes, that the record table parses, and that the runner reads as one set.

sub slurp ($path) {
    open my $handle, '<:encoding(UTF-8)', $path or die "read $path: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return $text;
}

# The shim names a kind as the first argument of a record call, and it writes the opening line by hand.
sub written ($shim) {
    my %kind = map { $_ => 1 } $shim =~ /(?:\b_record|\$record->)[(]\s*'(\w+)'/g;
    $kind{$_} = 1 for $shim =~ /syswrite\s+\$\w+,\s*"(\w+)\\t/g;
    return [ sort keys %kind ];
}

# The table maps a kind to the code that fills a field of the record, and the parser reads the opening line itself.
sub parsed ($table) {
    my %fields;
    while ( $table =~ /^[ ]{4}(\w+)\s*=>\s*sub\s*[(][^)]*[)]\s*[{](.*?)^[ ]{4}[}],/gms ) {
        my ( $kind, $body ) = ( $1, $2 );
        my %field = map { $_ => 1 } $body =~ /\$record->[{](\w+)[}]/g;
        $field{served} = 1 if $body =~ /\b_served[(]/;
        $fields{$kind} = [ sort keys %field ];
    }
    $fields{$_} = [] for $table =~ /\$kind\s+eq\s+'(\w+)'/g;
    return \%fields;
}

sub read_by ($runner) {
    my %field = map { $_ => 1 } $runner =~ /\$record->[{](\w+)[}]/g;
    return [ sort keys %field ];
}

sub violations ( $shim, $table, $runner ) {
    my %written = map { $_ => 1 } written($shim)->@*;
    my $parsed  = parsed($table);
    my %read    = map { $_ => 1 } read_by($runner)->@*;
    my @found   = (
        (
            map  { "the shim writes the kind $_, and the record table drops it" }
            grep { !$parsed->{$_} } sort keys %written
        ),
        (
            map  { "the record table parses the kind $_, and the shim never writes it" }
            grep { !$written{$_} } sort keys $parsed->%*
        ),
    );
    for my $kind ( sort keys $parsed->%* ) {
        push @found, map { "the record table parses the kind $kind into $_, and the runner never reads $_" }
          grep { !$read{$_} } $parsed->{$kind}->@*;
    }
    return \@found;
}

subtest 'the gate rejects a kind that one side writes and another side drops' => sub {
    my $shim = <<'PERL';
    _record( 'served', $target->{original} );
    $record->( 'hit', $target->{original}, $line );
    syswrite $handle, "begin\t$STATE{trace}\n";
PERL
    my $table = <<'PERL';
my %APPLY = (
    served => sub ( $record, $traced, $path, $value ) {
        my $file = _served( $record, $path );
        return;
    },
    hit => sub ( $record, $traced, $path, $value ) {
        $record->{hits}{$value} = 1;
        return;
    },
);
            if ( $kind eq 'begin' ) {
PERL
    my $runner = 'my $served = $record->{served}{$absolute}; my $hits = $record->{hits};';

    is written($shim), [qw(begin hit served)], 'the kinds of the calls, of the alias, and of the opening line';
    is parsed($table), { begin => [], hit => ['hits'], served => ['served'] },
      'the kinds of the table with their fields';
    is read_by($runner),                     [qw(hits served)], 'the fields that the runner reads';
    is violations( $shim, $table, $runner ), [],                'one set on the three sides';

    is violations( "$shim    _record( 'ghost', 1 );\n", $table, $runner ),
      ['the shim writes the kind ghost, and the record table drops it'], 'a kind that the table drops';
    is violations( $shim =~ s/^.*'hit'.*\n//mr, $table, $runner ),
      ['the record table parses the kind hit, and the shim never writes it'], 'a kind that the shim never writes';
    is violations( $shim, $table, 'my $served = $record->{served}{$absolute};' ),
      ['the record table parses the kind hit into hits, and the runner never reads hits'],
      'a field that the runner never reads';
};

my $shim     = slurp('lib/Test/Mutation/Shim.pm');
my $table    = slurp('lib/Test/Mutation/Record.pm');
my $evidence = slurp('lib/Test/Mutation/Evidence.pm');

my @kinds = qw(around begin blind end error hit lines outside seen);
is written($shim),                   \@kinds, 'the shim writes every documented record kind';
is [ sort keys parsed($table)->%* ], \@kinds, 'the decoder has one entry for each kind';
Gate::findings( 'records', violations( $shim, $table, $evidence ) );
Gate::checked( 'kinds that the shim writes',          scalar written($shim)->@*,      at_least => 9 );
Gate::checked( 'kinds that the record table reads',   scalar keys parsed($table)->%*, at_least => 8 );
Gate::checked( 'fields used to derive test evidence', scalar read_by($evidence)->@*,  at_least => 9 );

done_testing;
