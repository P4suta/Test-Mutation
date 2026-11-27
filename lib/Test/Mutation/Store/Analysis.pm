package Test::Mutation::Store::Analysis;
use v5.36;
use Cpanel::JSON::XS ();
use Types::Standard  qw(ArrayRef Dict HashRef InstanceOf Int Maybe Str Tuple Undef);
use Type::Params     qw(signature_for);
use Test::Mutation::Mutant;
use Test::Mutation::Store;
use Test::Mutation::Types qw(Refusal Rejected);

our $VERSION = '0.001';

my $JSON = Cpanel::JSON::XS->new->canonical;
my $FILE = Dict [
    problem  => Maybe [Str],
    left_out => Int,
    rejected => ArrayRef [Rejected],
    refusals => ArrayRef [Refusal],
    mutants  => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ]
];

signature_for read_file => ( positional => [ InstanceOf ['DBI::db'], Str, ArrayRef [Str] ], returns => Maybe [$FILE] );

sub read_file ( $db, $identity, $prefixes ) {
    return read_files( $db, [$identity], $prefixes )->{$identity};
}

signature_for read_files => (
    positional => [ InstanceOf ['DBI::db'], ArrayRef [Str], ArrayRef [Str] ],
    returns    => HashRef [$FILE],
);

sub read_files ( $db, $identities, $prefixes ) {
    return {} unless @$identities;
    my $slots   = join ',', ('?') x @$identities;
    my $catalog = $db->prepare("SELECT identity,facts FROM analysis WHERE identity IN ($slots)");
    $catalog->execute(@$identities);
    my %files;
    while ( my ( $id, $text ) = $catalog->fetchrow_array ) {
        $files{$id} = { $JSON->decode($text)->%*, mutants => [] };
    }
    my @patterns = map { "$_*" } grep { /\A[0-9a-f]{1,12}\z/ } @$prefixes;
    return \%files if !%files || ( @$prefixes && !@patterns );
    my @hits = sort keys %files;
    my $hits = join ',', ('?') x @hits;
    my %rows;
    do {
        my @group  = splice @patterns, 0, 64;
        my $filter = @group ? ' AND (' . join( ' OR ', ('id GLOB ?') x @group ) . ')' : q{};
        my $select = $db->prepare("SELECT analysis,ordinal,data FROM candidate WHERE analysis IN ($hits)$filter");
        $select->execute( @hits, @group );
        while ( my ( $id, $ordinal, $data ) = $select->fetchrow_array ) { $rows{$id}{$ordinal} = $data }
    } while (@patterns);
    for my $id ( keys %rows ) {
        $files{$id}{mutants} = [
            map  { Test::Mutation::Mutant->new( $JSON->decode( $rows{$id}{$_} ) ) }
            sort { $a <=> $b } keys $rows{$id}->%*
        ];
    }
    return \%files;
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

=head2 read_files

Returns the matching file analyses by identity with candidates in inventory order.

=head2 publish

Commits the facts and generated mutants of each previously unseen file analysis.

=cut
