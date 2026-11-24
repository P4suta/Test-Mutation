use v5.36;
use Test2::V0;
use lib 't/lib';
use Gate;
use Layouts;
use Oracle;
use Test::Mutation::Project;

# Every sequence of up to four suppression comments goes through the reference interpreter and through the parser of the tool.
# The fast gate reads the sequences of up to two comments, and this run adds the ones that need three or four.

my $LENGTH    = 4;
my @forms     = Layouts::forms();
my @sequences = Layouts::sequences( scalar @forms, $LENGTH );
my $workers   = Test::Mutation::Project::cpu_count();

sub named ($sequence) {
    return join ' / ', map { $_->{name} } @forms[ $sequence->@* ];
}

# The sequences of one share, each compared, as one record for each difference and one for the count of the share.
sub compared ( $share, $shares ) {
    my ( %found, $mutants );
    for my $sequence ( @sequences[ grep { $_ % $shares == $share } 0 .. $#sequences ] ) {
        my $layout = Layouts::rendered( @forms[ $sequence->@* ] );
        $mutants += Layouts::mutants($layout)->@*;
        $found{$_} ||= named($sequence) for Layouts::differences($layout)->@*;
    }
    return [ 'mutants', $mutants ], map { [ 'finding', $_, $found{$_} ] } sort keys %found;
}

subtest 'the comparison rejects a block that a second comment leaves open' => sub {
    my %form   = map { $_->{name} => $_ } @forms;
    my $layout = Layouts::rendered( @form{ 'block', 'block', 'end' } );
    my @after  = grep { $_->{line} == 8 } Layouts::mutants($layout)->@*;
    is $layout->{text} =~ tr/\n//, 9, 'the layout ends its block on the sixth of nine lines';
    is [ map { $_->{suppressed} } @after ], [ (1) x @after ],
      'the parser suppresses the statement after the end of the block';
    ok scalar(@after), 'and that statement has mutants';
    is Layouts::differences($layout),
      [
        'the parser accepts a second no mutate inside an open block',
        'the parser starts a second block inside an open block and never ends the first one',
      ],
      'the comparison names both the layout that the parser accepts and what the parser makes of it';
};

my $shares  = 4 * $workers;
my $records = Oracle::each_file( [ map { [ "share $_", $_, $shares ] } 0 .. $shares - 1 ],
    $workers, sub ( $name, $share, $of ) { return compared( $share, $of ) } );
my ( %found, $mutants );
for my $record ( $records->@* ) {
    my ( $share, $kind, @fields ) = $record->@*;
    $mutants += $fields[0]              if $kind eq 'mutants';
    $found{ $fields[0] } ||= $fields[1] if $kind eq 'finding';
}
note "$_, as in: $found{$_}" for sort keys %found;
Gate::findings( 'mutants-suppress-layouts', [ sort keys %found ] );
Gate::checked( 'forms of a comment',  scalar @forms,     at_least => 13 );
Gate::checked( 'layouts',             scalar @sequences, at_least => 30_941 );
Gate::checked( 'mutants of a layout', $mutants,          at_least => 450_000 );

done_testing;
