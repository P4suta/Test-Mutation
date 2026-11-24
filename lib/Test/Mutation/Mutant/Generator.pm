package Test::Mutation::Mutant::Generator;
use v5.36;
use Digest::SHA     ();
use Encode          ();
use Types::Standard qw(ArrayRef InstanceOf Maybe Num);
use Type::Params    qw(signature_for);
use Test::Mutation::Mutant;
use Test::Mutation::Site;
use Test::Mutation::Types qw(Analysis);

our $VERSION = '0.001';

signature_for generate => (
    named => [
        source   => InstanceOf ['Test::Mutation::Source'],
        analysis => Analysis,
        mutators => ArrayRef [ InstanceOf ['Test::Mutation::Mutator'] ],
        perl     => Maybe [Num],
        { default => undef },
    ],
    returns => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ],
);

sub generate ($arg) {
    my $source = $arg->source;
    my ( %seen, @mutants );
    for my $site ( map { _settle( $_, $arg->perl ) } $arg->analysis->{sites}->@* ) {
        for my $mutator ( $arg->mutators->@* ) {
            for my $mutation ( $mutator->mutations($site)->@* ) {
                my $replacement = $mutation->{replacement};
                my $change      = join "\0", $site->start, $site->end, $replacement;
                next if $seen{$change};
                $seen{$change} = 1;
                my $from = $source->position_of( $site->start );
                push @mutants,
                  Test::Mutation::Mutant->new(
                    id          => _id( $source->path, $site, $mutator->name, $replacement ),
                    path        => $source->path,
                    mutator     => $mutator->name,
                    start       => $site->start,
                    end         => $site->end,
                    original    => $site->text,
                    replacement => $replacement,
                    description => $mutation->{description},
                    from        => $from,
                    to          => $source->position_of( $site->end ),
                    scope       => $site->scope,
                    comparable  => $site->comparable,
                    suppressed  => _suppressed( $arg->analysis->{suppressions}, $from->[0], $mutator->name ),
                  );
            }
        }
    }
    return \@mutants;
}

# The version of Perl equals a literal on one interpreter alone.
# On every other interpreter the comparison gives one result on both sides of its boundary.
sub _settle ( $site, $perl ) {
    my $literal = $site->facts->{version};
    return $site if !defined $literal || !defined $perl || $literal == $perl;
    return Test::Mutation::Site->new( ( map { $_ => $site->$_ } qw(kind text start end role scope comparable) ),
        facts => { $site->facts->%*, settled => 1 }, );
}

sub _id ( $path, $site, $name, $replacement ) {
    my $key = join "\0", $path, $site->start, $site->end, $name, $replacement;
    return substr Digest::SHA::sha256_hex( Encode::encode( 'UTF-8', $key ) ), 0, 12;
}

sub _suppressed ( $ranges, $line, $name ) {
    my @covering = grep { $line >= $_->{first} && ( !defined $_->{last} || $line <= $_->{last} ) } $ranges->@*;
    return (
        grep {
            !$_->{names}
              || grep { $_ eq $name }
              $_->{names}->@*
        } @covering
    ) ? 1 : 0;
}

1;

__END__

=head1 NAME

Test::Mutation::Mutant::Generator - turn sites and mutators into mutants

=head1 SYNOPSIS

    my $mutants = Test::Mutation::Mutant::Generator::generate(
        source   => $source,
        analysis => Test::Mutation::Syntax::PPI::analyze($source),
        mutators => Test::Mutation::Mutator::Catalog::mutators(),
    );

=head1 FUNCTIONS

=head2 generate

Returns one L<Test::Mutation::Mutant> for every distinct replacement of every site, in source order.
Two mutators that propose the same replacement for the same span yield one mutant, credited to the first.
A mutant on a line that a C<## no mutate> comment covers is marked as suppressed.
C<perl> is the version of the interpreter that runs the tests, as C<$]> gives it.
A comparison of C<$]> with another number has one result there, so the change of its boundary yields no mutant.

=cut
