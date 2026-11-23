package Permutl::Mutant::Generator;
use v5.36;
use Digest::SHA     ();
use Encode          ();
use Types::Standard qw(ArrayRef HashRef InstanceOf);
use Type::Params    qw(signature_for);
use Permutl::Mutant;

our $VERSION = '0.001';

signature_for generate => (
    named => [
        source   => InstanceOf ['Permutl::Source'],
        analysis => HashRef,
        mutators => ArrayRef [ InstanceOf ['Permutl::Mutator'] ],
    ],
    returns => ArrayRef [ InstanceOf ['Permutl::Mutant'] ],
);

sub generate ($arg) {
    my $source = $arg->source;
    my ( %seen, @mutants );
    for my $site ( $arg->analysis->{sites}->@* ) {
        for my $mutator ( $arg->mutators->@* ) {
            for my $mutation ( $mutator->mutations($site)->@* ) {
                my $replacement = $mutation->{replacement};
                my $change      = join "\0", $site->start, $site->end, $replacement;
                next if $seen{$change};
                $seen{$change} = 1;
                my $from = $source->position_of( $site->start );
                push @mutants,
                  Permutl::Mutant->new(
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

sub _id ( $path, $site, $name, $replacement ) {
    my $key = join "\0", $path, $site->start, $site->end, $name, $replacement;
    return substr Digest::SHA::sha256_hex( Encode::encode( 'UTF-8', $key ) ), 0, 12;
}

sub _suppressed ( $ranges, $line, $name ) {
    for my $range ( $ranges->@* ) {
        next     if $line < $range->{first};
        next     if defined $range->{last} && $line > $range->{last};
        return 1 if !$range->{names} || grep { $_ eq $name } $range->{names}->@*;
    }
    return 0;
}

1;

__END__

=head1 NAME

Permutl::Mutant::Generator - turn sites and mutators into mutants

=head1 SYNOPSIS

    my $mutants = Permutl::Mutant::Generator::generate(
        source   => $source,
        analysis => Permutl::Syntax::PPI::analyze($source),
        mutators => Permutl::Mutator::Catalog::mutators(),
    );

=head1 FUNCTIONS

=head2 generate

Returns one L<Permutl::Mutant> for every distinct replacement of every site, in source order.
Two mutators that propose the same replacement for the same span yield one mutant, credited to the first.
A mutant on a line that a C<## no mutate> comment covers is marked as suppressed.

=cut
