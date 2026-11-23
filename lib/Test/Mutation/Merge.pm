package Test::Mutation::Merge;
use v5.36;
use List::Util      qw(all first max min sum0 uniq);
use Types::Standard qw(ArrayRef Dict InstanceOf Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Result;

our $VERSION = '0.001';

signature_for merge => (
    positional => [ ArrayRef [ Dict [ name => Str, result => InstanceOf ['Test::Mutation::Result'] ] ] ],
    returns    => InstanceOf ['Test::Mutation::Result'],
);

sub merge ($reports) {
    die "merge needs at least one report\n" if !$reports->@*;
    my @parts   = _parts($reports);
    my @results = map { $_->{result} } @parts;
    my $count   = $results[0]->inventory->{mutants};
    my $parts   = scalar @parts;

    my %seen;
    for my $entry ( map { $_->entries->@* } @results ) {
        my $id = $entry->{mutant}->id;
        die "mutant $id appears in more than one part\n" if $seen{$id};
        $seen{$id} = 1;
    }
    for my $index ( 0 .. $#parts ) {
        my $rounded  = $count - $index + $parts - 1;
        my $expected = int $rounded / $parts;
        my $held     = scalar $results[$index]->entries->@*;
        my $number   = $index + 1;
        die "$parts[$index]{name} holds $held mutants, and part $number of $parts has $expected\n"
          if $held != $expected;
    }

    my %duration;
    for my $test ( map { $_->tests->@* } @results ) {
        my $name = $test->{name};
        $duration{$name} = max( $test->{duration}, exists $duration{$name} ? $duration{$name} : () );
    }
    my %problem = map { $_->{path} => $_ } reverse map { $_->problems->@* } @results;
    return Test::Mutation::Result->new(
        root              => $results[0]->root,
        sources           => { map { $_->sources->%* } @results },
        tests             => [ map { { name => $_, duration => $duration{$_} } } sort keys %duration ],
        entries           => [ map { $results[ $_ % $parts ]->entries->[ int( $_ / $parts ) ] } 0 .. $count - 1 ],
        problems          => [ map { $problem{$_} } sort keys %problem ],
        warnings          => [ uniq map { $_->warnings->@* } @results ],
        baseline_failures => [],
        jobs              => max( map { $_->jobs } @results ),
        parallel_safe     => ( all { $_->parallel_safe } @results ) ? 1 : 0,
        interrupted       => ( first { defined } map { $_->interrupted } @results ),
        reused            => sum0( map { $_->reused } @results ),
        inventory         => $results[0]->inventory,
        started           => min( map { $_->started } @results ),
        finished          => max( map { $_->finished } @results ),
    );
}

sub _parts ($reports) {
    my ( @parts, $whole );
    for my $report ( $reports->@* ) {
        my ( $name, $result ) = $report->@{qw(name result)};
        die "$name is the report of a whole run, not of a part\n" if !defined $result->shard;
        die "$name names no inventory\n"                          if !$result->inventory;
        die "$name has failing tests in its unmodified run, so its part measured nothing\n"
          if $result->baseline_failures->@*;
        my ( $part, $of ) = split m{/}, $result->shard;
        $whole ||= { name => $name, part => $part, of => $of, digest => $result->inventory->{digest} };
        die "$whole->{name} holds part $whole->{part} of $whole->{of}, and $name holds part $part of $of\n"
          if $of != $whole->{of};
        die "$name covers other mutants than $whole->{name}\n" if $result->inventory->{digest} ne $whole->{digest};
        die "$parts[$part - 1]{name} and $name both hold part $part of $of\n" if $parts[ $part - 1 ];
        $parts[ $part - 1 ] = $report;
    }
    my @missing = grep { !$parts[ $_ - 1 ] } 1 .. $whole->{of};
    return @parts if !@missing;
    my $last = pop @missing;
    die "part $last of $whole->{of} is missing\n" if !@missing;
    my $list = join @missing > 1 ? ', ' : q{ }, @missing, "and $last";
    die "parts $list of $whole->{of} are missing\n";
}

1;

__END__

=head1 NAME

Test::Mutation::Merge - join the results of the parts of one run

=head1 SYNOPSIS

    my $whole = Test::Mutation::Merge::merge(
        [
            { name => 'first/mutation.json',  result => $first },
            { name => 'second/mutation.json', result => $second },
        ]
    );

=head1 DESCRIPTION

C<mutation run --shard K/N> measures one of C<N> parts of the mutants.
This module joins the results of all parts into the result that one run without C<--shard> returns.

=head1 FUNCTIONS

=head2 merge

Takes the results with the names that error messages use, and returns one L<Test::Mutation::Result>.
The function dies unless the results are the parts 1 to C<N> of one run, each exactly once.
Every result must name the same C<N> and the same inventory, and hold the mutants of its part.

The merged result lists the mutants in the order of a whole run.
It keeps each test with its longest duration, each warning and problem once, the largest job count, and the whole time span.

=cut
