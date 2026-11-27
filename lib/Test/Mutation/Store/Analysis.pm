package Test::Mutation::Store::Analysis;
use v5.36;
use JSON::PP        ();
use Types::Standard qw(ArrayRef Dict InstanceOf Int Maybe Str Tuple Undef);
use Type::Params    qw(signature_for);
use Test::Mutation::Mutant;
use Test::Mutation::Store;
use Test::Mutation::Types qw(Refusal Rejected);

our $VERSION = '0.001';

my $JSON = JSON::PP->new->canonical;
my $FILE = Dict [
    problem  => Maybe [Str],
    left_out => Int,
    rejected => ArrayRef [Rejected],
    refusals => ArrayRef [Refusal],
    mutants  => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ]
];

signature_for read_file => ( positional => [ InstanceOf ['DBI::db'], Str, ArrayRef [Str] ], returns => Maybe [$FILE] );

sub read_file ( $db, $identity, $prefixes ) {
    my ($text) = $db->selectrow_array( 'SELECT facts FROM analysis WHERE identity = ?', undef, $identity );
    return unless defined $text;
    my $facts = $JSON->decode($text);
    my $rows;
    if (@$prefixes) {
        my %rows;
        my $select = $db->prepare('SELECT ordinal,data FROM candidate WHERE analysis = ? AND id GLOB ?');
        for my $prefix ( grep { /\A[0-9a-f]{1,12}\z/ } @$prefixes ) {
            $select->execute( $identity, "$prefix*" );
            $rows{ $_->[0] } = $_->[1] for $select->fetchall_arrayref->@*;
        }
        $rows = [ map { $rows{$_} } sort { $a <=> $b } keys %rows ];
    }
    else {
        $rows =
          $db->selectcol_arrayref( 'SELECT data FROM candidate WHERE analysis = ? ORDER BY ordinal', undef, $identity );
    }
    $facts->{mutants} = [ map { Test::Mutation::Mutant->new( $JSON->decode($_) ) } @$rows ];
    return $facts;
}

signature_for publish => ( positional => [ Str, ArrayRef [ Tuple [ Str, $FILE ] ] ], returns => Undef );

sub publish ( $path, $pending ) {
    my $db = Test::Mutation::Store::database($path);
    Test::Mutation::Store::transaction(
        $db,
        sub {
            my $file      = $db->prepare('INSERT OR IGNORE INTO analysis VALUES (?,?)');
            my $candidate = $db->prepare('INSERT INTO candidate VALUES (?,?,?,?)');
            for my $queued (@$pending) {
                my ( $identity, $result ) = @$queued;
                my %facts   = %$result;
                my $mutants = delete $facts{mutants};
                next unless 0 + $file->execute( $identity, $JSON->encode( \%facts ) );
                my $order = 0;
                for my $mutant (@$mutants) {
                    $candidate->execute( $identity, $order++, $mutant->id, $JSON->encode( { $mutant->%* } ) );
                }
            }
            return 1;
        }
    );
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Store::Analysis - index generated mutants by file analysis and identifier

=head1 FUNCTIONS

=head2 read_file

Returns the facts for a matching analysis and the mutants matching the requested prefixes in inventory order.
An empty prefix list selects the whole file.

=head2 publish

Commits the facts and generated mutants of each previously unseen file analysis.

=cut
