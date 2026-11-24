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
my %together = ( loading => 'use' );
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
sub passes_under_prove ( $project, $built ) {
    my @tests   = sort map { $_->{test} } values $built->%*;
    my $copy    = $project->copy;
    my $verdict = $copy->proves(@tests);
    $copy->discard;
    return is $verdict, { map { $_ => 'pass' } @tests }, "prove passes @tests";
}

# The members of an axis that touch their own process alone share one project and one run.
# A member whose test fails without a mutant is a finding, and the others are measured without it.
sub together ( $axis, @names ) {
    my ( $project, $built, $run, @failed );
    while (@names) {
        $project = Discovery::Project->new;
        $built   = $zoo->build( $project, @names );
        passes_under_prove( $project, $built ) if !@failed;
        $run = $engine->run( $project, %settings );
        $runs++;
        my %broken  = map { $_ => 1 } $run->{baseline_failures}->@*;
        my %failing = map { $_ => 1 } grep { $broken{ $built->{$_}{test} } } @names;
        last if !%failing;
        push @failed, sort keys %failing;
        @names = grep { !$failing{$_} } @names;
    }
    my $reference = $built->{ $together{$axis} } or die "the reference of $axis fails without a mutant\n";
    my @found     = (
        ( map { "$axis=$_: the unmodified run fails" } @failed ),
        ( map { "$axis: $_" } findings( \@run, run => $run ) ),
        findings( ['I5'], run => $run ),
        ( map { "$axis=$reference->{name}: $_" } findings( ['I7'], run => $run, member => $reference ) ),
    );
    for my $name ( grep { $_ ne $reference->{name} } @names ) {
        push @found,
          map { "$axis=$name: $_" }
          findings( [ 'I8', 'I6' ], run => $run, member => $built->{$name}, reference => $reference );
    }
    $compared += keys $run->{mutants}->%*;
    $ran{"$axis=$_"}++ for @names, @failed;
    return @found;
}

# A member that changes files gets a project and a run of its own, so its damage reaches no other member.
sub alone ( $axis, $name ) {
    my $project = Discovery::Project->new;
    my $member  = $zoo->build( $project, $name )->{$name};
    passes_under_prove( $project, { $name => $member } );
    my $run = $engine->run( $project, %settings, jobs => defined $member->{jobs} ? $member->{jobs} : 2 );
    $runs++;
    $compared += keys $run->{mutants}->%*;
    $ran{"$axis=$name"}++;
    $project->discard;
    return ( findings( ['I5'], run => $run ),
        map { "$axis=$name: $_" } findings( [ @run, 'I7', 'I6' ], run => $run, member => $member ) );
}

push $found{fast}->@*, together( 'loading', Discovery::Zoo::names('loading') );
push $found{fast}->@*, map { alone( 'files', $_ ) } Discovery::Zoo::names('files');

Discovery::Tier::report( 'zoo', \%found );
my @members;
for my $axis (qw(loading files)) {
    push @members, map { "$axis=$_" } Discovery::Zoo::names($axis);
}
is [ sort keys %ran ], [ sort @members ], 'every member of every axis ran';
Gate::checked( 'members',            scalar keys %ran, at_least => 27 );
Gate::checked( 'runs',               $runs,            at_least => 11 );
Gate::checked( 'mutants in the zoo', $compared,        at_least => 200 );

done_testing;
