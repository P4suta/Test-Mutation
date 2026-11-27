package Test::Mutation::Mutant::Generator;
use v5.36;
use Digest::SHA     ();
use Encode          ();
use Types::Standard qw(ArrayRef Dict InstanceOf Maybe Num);
use Type::Params    qw(signature_for);
use Test::Mutation::Mutant;
use Test::Mutation::Mutant::Validity;
use Test::Mutation::Mutator::Providers;
use Test::Mutation::Site;
use Test::Mutation::Suppression;
use Test::Mutation::Types qw(Analysis Rejected);

our $VERSION = '0.001';

signature_for generate => (
    named => [
        source   => InstanceOf ['Test::Mutation::Source'],
        analysis => Analysis,
        mutators => ArrayRef [ InstanceOf ['Test::Mutation::Mutator'] ],
        perl     => Maybe [Num],
        { default => undef },
    ],
    returns => Dict [
        mutants  => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ],
        rejected => ArrayRef [Rejected],
    ],
);

sub generate ($arg) {
    my $source   = $arg->source;
    my $analysis = $arg->analysis;
    my $rules    = Test::Mutation::Mutant::Validity->new(
        text     => $source->text,
        heredocs => $analysis->{heredocs},
        names    => $analysis->{names},
    );
    my ( %result, @mutants, @rejected );
    for my $site ( map { _settle( $_, $arg->perl ) } $analysis->{sites}->@* ) {
        my $from = $source->position_of( $site->start );
        for my $mutator ( $arg->mutators->@* ) {
            for my $mutation ( $mutator->mutations($site)->@* ) {
                my ( $replacement, $rule ) = _checked( $rules, $site, $mutation, \%result );
                if ( defined $rule ) {
                    push @rejected, { mutator => $mutator->name, line => $from->[0], rule => $rule };
                    next;
                }

                # A mutator that proposes a call learns the name of the call from the boundary.
                my $description = $mutation->{description};
                $description = sprintf $description, $replacement if defined $mutation->{calls};
                my $directive = Test::Mutation::Suppression::covering( $analysis->{suppressions}{directives},
                    $from->[0], $mutator->name );
                push @mutants,
                  Test::Mutation::Mutant->new(
                    id              => _id( $source->path, $site, $mutator->name, $replacement ),
                    path            => $source->path,
                    mutator         => $mutator->name,
                    start           => $site->start,
                    end             => $site->end,
                    original        => $site->text,
                    replacement     => $replacement,
                    description     => $description,
                    from            => $from,
                    to              => $source->position_of( $site->end ),
                    scope           => $site->scope,
                    comparable      => $site->comparable,
                    introduced_call => defined $mutation->{calls}
                      && defined $site->facts->{call_offset}
                      && !Test::Mutation::Mutator::Providers::is_core($replacement)
                      && $replacement !~ /\ACORE::/ ? [ $replacement, $site->facts->{call_offset} ] : undef,
                    suppressed         => $directive ? 1                    : 0,
                    suppression_reason => $directive ? $directive->{reason} : undef,
                  );
            }
        }
    }
    return { mutants => \@mutants, rejected => \@rejected };
}

# Every change passes here, whatever mutator proposed it.
# The answer is the text to write, or the rule that refuses the change.
sub _checked ( $rules, $site, $mutation, $results ) {
    my $replacement = $mutation->{replacement};
    if ( defined $mutation->{calls} ) {
        $replacement = $rules->resolved_call( $site->text, $mutation->{calls}, $site->facts->{local_calls} || [] );
        return ( undef, 'unresolved-call' ) if !defined $replacement;
    }
    my $change = $rules->change( $site, $replacement );
    return ( undef, 'same-text' ) if !defined $change;
    my $rule = $rules->refusal( $site, $replacement );
    return ( undef, $rule ) if defined $rule;

    # Two changes with one resulting text are one mutant, and the first proposal keeps it.
    return ( undef, 'same-result' ) if $results->{$change};
    $results->{$change} = 1;
    return ( $replacement, undef );
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

1;

__END__

=head1 NAME

Test::Mutation::Mutant::Generator - turn sites and mutators into mutants

=head1 SYNOPSIS

    my $generated = Test::Mutation::Mutant::Generator::generate(
        source   => $source,
        analysis => Test::Mutation::Syntax::PPI::analyze($source),
        mutators => Test::Mutation::Mutator::Catalog::mutators(),
    );
    my @mutants = $generated->{mutants}->@*;

=head1 DESCRIPTION

The generator is the one boundary that every mutant passes.
It asks the rules of L<Test::Mutation::Mutant::Validity> about each change that a mutator proposes, so no mutator keeps a guard of its own.

=head1 FUNCTIONS

=head2 generate

Returns a hash reference with two keys.
C<mutants> holds one L<Test::Mutation::Mutant> for every change that stands, in source order.
C<rejected> holds every change that a rule refused, with the mutator, the line, and the rule.
Two changes with one resulting text yield one mutant, credited to the first proposal.
A mutator that proposes a call of another function gets the name that the file resolves, with its package where the bare name may be out of reach.
A mutant whose first line a C<## no mutate> comment covers is marked as suppressed, with the reason of the comment.
C<perl> is the version of the interpreter that runs the tests, as C<$]> gives it.
A comparison of C<$]> with another number has one result there, so the change of its boundary yields no mutant.

=cut
