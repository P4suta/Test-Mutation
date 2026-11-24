use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/discovery/lib';
use Gate;
use Discovery::Check;
use Discovery::Engine;
use Discovery::Known;
use Discovery::Project;
use Discovery::Tier;
use Discovery::Zoo;

# The hostile test zoo: the same cells under one hostile behavior for each member.
# The verdicts of a member equal the truth of the cells, the run leaves nothing behind, and a deviation is no silent one.

Discovery::Tier::announce();
my $engine = Discovery::Engine->new;
my $known  = Discovery::Known->new(
    tests => 1,
    cells => [
        { body => 'return $x >= $y ? 1 : 0', rows => [ [ 4, 1 ], [ 0, 2 ] ], test => 't/a.t' },
        { body => 'return $x + $y',          rows => [ [ 2, 3 ] ],           test => 't/a.t' },
        { body => 'return $x * $y',          rows => [ [ 1, 1 ] ],           test => undef },
    ],
);
my $zoo      = Discovery::Zoo->new( known => $known );
my @run      = qw(completes I2 I3 I4);
my %settings = ( sources => Discovery::Zoo::sources(), equivalence => 0 );
my $plain    = 'use';
my ( %found, %ran );
my ( $runs,  $compared ) = ( 0, 0 );

sub findings ( $names, @arguments ) {
    return Discovery::Check::findings( $names, known => $known, coverage => 'line', @arguments );
}

subtest 'the comparison of two members rejects a lost kill and a silent one' => sub {
    my $mutant = sub ( $path, $line ) {
        return { path => $path, line => $line, column => 41, end_line => $line, end_column => 43, replacement => '<' };
    };
    my %member = (
        use     => { target => 'lib/Zoo/Use.pm',     test => 't/use.t',     shift => 0 },
        require => { target => 'lib/Zoo/Require.pm', test => 't/require.t', shift => 0 },
        script  => { target => 'script/perl-x.pl',   test => 't/perl-x.t',  shift => 1 },
    );
    my $run = sub ( $status, @warnings ) {
        return {
            mutants => {
                a => $mutant->( 'lib/Zoo/Use.pm',     4 ),
                b => $mutant->( 'lib/Zoo/Require.pm', 4 ),
                c => $mutant->( 'script/perl-x.pl',   5 ),
                d => $mutant->( 'script/perl-x.pl',   9 ),
            },
            status   => { a => 'Killed', b => $status, c => 'Killed', d => 'Killed' },
            reason   => { b => $status eq 'NoVerdict' ? 'the test loaded the file without the hook' : undef },
            by       => { a => 't/use.t', b => 't/require.t', c => 't/perl-x.t' },
            warnings => \@warnings,
        };
    };
    my $between = sub ( $name, $observed ) {
        return [ findings( [ 'I8', 'I6' ], run => $observed, member => $member{$name}, reference => $member{use} ) ];
    };
    is $between->( 'require', $run->('Killed') ), [], 'two members with the same verdicts';
    is $between->( 'script', $run->('Killed') ), [],
      'a member whose cells stand one line lower, with a mutant outside its cells';
    is $between->( 'require', $run->('NoCoverage') ),
      [
        'I8 the run gives NoCoverage where the reference style gives Killed',
        'I6 the verdicts deviate without a warning or a reason'
      ],
      'a lost kill that nothing reports';
    is $between->( 'require', $run->( 'NoCoverage', 't/require.t loads lib/Zoo/Require.pm around the hook' ) ),
      ['I8 the run gives NoCoverage where the reference style gives Killed'], 'a lost kill that a warning names';
    is $between->( 'require', $run->( 'NoCoverage', 't/other.t loads lib/Other.pm around the hook' ) ),
      [
        'I8 the run gives NoCoverage where the reference style gives Killed',
        'I6 the verdicts deviate without a warning or a reason'
      ],
      'a warning about another test reports nothing';
    is $between->( 'require', $run->('NoVerdict') ),
      ['I8 the run gives NoVerdict where the reference style gives Killed'],
      'a lost kill that the reason of the status reports';

    my $absent = $run->('Killed');
    delete $absent->{mutants}{b};
    is $between->( 'require', $absent ),
      [
        'I8 the run lists no mutant in the cells of the style',
        'I6 the verdicts deviate without a warning or a reason'
      ],
      'a member without a mutant';
};

# prove is the oracle of the unmodified run: every member passes there, in a copy that its tests may change.
# The tests run side by side, so a test that leaves a process with its output costs the time of one such process.
sub passes_under_prove ( $project, $built, @arguments ) {
    my @tests   = sort map { $_->{test} } values $built->%*;
    my $copy    = $project->copy;
    my $verdict = $copy->proves( '-j4', @arguments, @tests );
    $copy->discard;

    # A process that a test left under prove would count as one that the tool left.
    $project->reap;
    return is $verdict, { map { $_ => 'pass' } @tests }, "prove passes @tests";
}

# The members of an axis that touch their own process alone share one project and one run with the plain member.
# A member whose test fails without a mutant is a finding, and the others are measured without it.
# The full tier repeats such a run under other settings, which come in `more`.
sub together ( $axis, $members, %more ) {
    my @members = $members->@*;
    my @names   = ( ( grep { $_ eq $plain } @members ) ? () : $plain, @members );
    my @truth   = defined $more{coverage} ? ( coverage => $more{coverage} ) : ();
    my ( $project, $built, $run, @failed );
    while (@names) {
        $project = Discovery::Project->new;
        $built   = $zoo->build( $project, @names );
        passes_under_prove( $project, $built ) if !@failed && !%more;
        $run = $engine->run( $project, %settings, %more );
        note sprintf '%s: the run of %d members took %.1f seconds', $axis, scalar @names, $run->{seconds};
        $runs++;
        my %broken  = map { $_ => 1 } $run->{baseline_failures}->@*;
        my %failing = map { $_ => 1 } grep { $broken{ $built->{$_}{test} } } @names;
        last if !%failing;
        push @failed, sort keys %failing;
        @names = grep { !$failing{$_} } @names;
    }
    my $reference = $built->{$plain} or die "the plain member of $axis fails without a mutant\n";
    my @found     = (
        ( map { "$axis=$_: the unmodified run fails" } @failed ),
        ( map { "$axis: $_" } findings( [ @run, 'I1' ], run => $run ) ),
        findings( ['I5'], run => $run ),
        ( map { "$axis=$plain: $_" } findings( ['I7'], run => $run, member => $reference, @truth ) ),
    );
    for my $name ( grep { $_ ne $plain } @names ) {
        push @found,
          map { "$axis=$name: $_" }
          findings( [ 'I8', 'I6' ], run => $run, member => $built->{$name}, reference => $reference );
    }
    $compared += keys $run->{mutants}->%*;
    $ran{"$axis=$_"}++ for @members;
    return @found;
}

# A member that changes more than its own process gets a project and a run of its own.
sub alone ( $axis, $name ) {
    my $project = Discovery::Project->new( name => Discovery::Zoo::directory($name) );
    my $member  = $zoo->build( $project, $name )->{$name};
    passes_under_prove( $project, { $name => $member }, $member->{prove}->@* );
    my $run = $engine->run( $project, %settings, $member->{settings}->%*, cpu => $member->{idle} );
    note sprintf '%s=%s: the run took %.1f seconds', $axis, $name, $run->{seconds};
    $runs++;
    $compared += keys $run->{mutants}->%*;
    $ran{"$axis=$name"}++;
    $project->discard;
    my @observed =
      ( run => $run, member => $member, idle => $member->{idle}, floor => $member->{settings}{timeout_floor} );
    return ( findings( ['I5'], run => $run ),
        map { "$axis=$name: $_" } findings( [ @run, 'I1', 'I7', 'I6' ], @observed ) );
}

my @members;
for my $axis (qw(loading process io taint files path)) {
    my @names = Discovery::Zoo::names($axis);
    push @members, map { "$axis=$_" } @names;
    my @shared = grep { !Discovery::Zoo::alone($_) } @names;
    push $found{fast}->@*, together( $axis, \@shared ) if @shared;
    push $found{fast}->@*, map { alone( $axis, $_ ) } grep { Discovery::Zoo::alone($_) } @names;
}

# The full tier measures the loading styles again in the project itself, under file coverage, and with one job.
# A finding of the fast tier says nothing new there, and each other one names the setting it came from.
if ( Discovery::Tier::full() ) {
    my %fast   = map  { $_ => 1 } $found{fast}->@*;
    my @styles = grep { !Discovery::Zoo::alone($_) } Discovery::Zoo::names('loading');
    for my $variant (
        [ 'in the project', in_place => 1 ],
        [ 'file coverage',  coverage => 'file' ],
        [ 'one job',        jobs     => 1 ]
      )
    {
        my ( $label, @more ) = $variant->@*;
        push $found{full}->@*, map { "$label, $_" } grep { !$fast{$_} } together( 'loading', \@styles, @more );
    }
}

Discovery::Tier::report( 'zoo', \%found );
is [ sort keys %ran ], [ sort @members ], 'every member of every axis ran';
Gate::checked( 'members',            scalar keys %ran, at_least => 62 );
Gate::checked( 'runs',               $runs,            at_least => 18 );
Gate::checked( 'mutants in the zoo', $compared,        at_least => 500 );

done_testing;
