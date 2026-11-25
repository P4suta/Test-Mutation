use v5.36;
use Test2::V0;
use Config ();
use lib 't/lib', 'xt/discovery/lib';
use Capability;
use Gate;
use Discovery::Check;
use Discovery::Engine;
use Discovery::Known;
use Discovery::Project;
use Discovery::Tier;
use Discovery::Waiter;
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
my %settings = ( sources => Discovery::Zoo::sources(), equivalence => 0, enable => ['comparison-boundary'] );
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

    my $outside = sub ($observed) {
        return [
            findings(
                ['I8'],
                run             => $observed,
                member          => $member{require},
                reference       => $member{use},
                expected_reason => 'outside-copy'
            )
        ];
    };
    my $escaped = $run->('NoVerdict');
    $escaped->{reason}{b} = 'outside-copy';
    is $outside->($escaped), [], 'a hard-coded source path reports that the test escaped its copy';
    $escaped->{reason}{b} = 'no-record';
    ok scalar $outside->($escaped)->@*,           'a different cause cannot stand for an outside load';
    ok scalar $outside->( $run->('Killed') )->@*, 'a test that ran the original source cannot kill a mutant';
    ok scalar $outside->($absent)->@*,            'every mutant in the reference cells is still required';
    my $completed = { baseline_failures => [], exit => 4, reported => 1 };
    is [ findings( ['completes'], run => $completed, expected_exit => 4 ) ], [],
      'outside the copy the run reports an inconclusive outcome';
    $completed->{exit} = 0;
    is [ findings( ['completes'], run => $completed, expected_exit => 4 ) ], ['the run exits with status 0'],
      'a successful gate cannot hide an inconclusive run';
};

# prove is the oracle of the unmodified run: every member passes there, in a copy that its tests may change.
# The tests run side by side, so a test that leaves a process with its output costs the time of one such process.
sub passes_under_prove ( $project, $built, @arguments ) {
    my @tests       = sort map { $_->{tests}->@* } values $built->%*;
    my %environment = map      { $_->{environment}->%* } values $built->%*;
    my $copy        = $project->copy;
    local @ENV{ keys %environment } = values %environment;
    my $verdict = $copy->proves( '-j4', @arguments, @tests );
    $copy->discard;

    # A process that a test left under prove would count as one that the tool left.
    $project->reap;
    return is $verdict, { map { $_ => 'pass' } @tests }, "prove passes @tests";
}

# The members of an axis that touch their own process alone share one project and one run with the plain member.
# A member whose test fails without a mutant is a finding, and the others are measured without it.
# The full tier repeats such a run under other settings, which come in `more`, and without the question to prove.
sub together ( $axis, $members, %more ) {
    my $sanity  = exists $more{sanity} ? delete $more{sanity} : !%more;
    my @members = $members->@*;
    my @names   = ( ( grep { $_ eq $plain } @members ) ? () : $plain, @members );
    my @truth   = defined $more{coverage} ? ( coverage => $more{coverage} ) : ();
    my ( $project, $built, $run, @failed );
    while (@names) {
        $project = Discovery::Project->new;
        $built   = $zoo->build( $project, @names );
        passes_under_prove( $project, $built ) if $sanity && !@failed;
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
    my $outside   = $built->{'absolute-original'} && !$more{in_place};
    my @found     = (
        ( map { "$axis=$_: the unmodified run fails" } @failed ),
        ( map { "$axis: $_" } findings( [ @run, 'I1' ], run => $run, expected_exit => $outside ? 4 : 0 ) ),
        findings( ['I5'], run => $run ),
        ( map { "$axis=$plain: $_" } findings( ['I7'], run => $run, member => $reference, @truth ) ),
    );
    for my $name ( grep { $_ ne $plain } @names ) {
        my $member = $built->{$name};

        # A member whose behavior turns the statuses has a truth of its own, and no other member shows it.
        my @compared = $member->{turns}->%* ? @truth : ( reference => $reference );
        push @compared, expected_reason => 'outside-copy' if $outside && $name eq 'absolute-original';
        push @found,
          map { "$axis=$name: $_" }
          findings( [ ( $member->{turns}->%* ? 'I7' : 'I8' ), 'I6' ], run => $run, member => $member, @compared );
    }
    $compared += keys $run->{mutants}->%*;
    $ran{"$axis=$_"}++ for @members;
    return @found;
}

# A member that changes more than its own process gets a project and a run of its own.
# The full tier repeats such a run under other settings, which come in `more`, and without the question to prove.
sub alone ( $axis, $name, %more ) {
    my $project = Discovery::Project->new( name => Discovery::Zoo::directory($name) );
    my $member  = $zoo->build( $project, $name )->{$name};
    passes_under_prove( $project, { $name => $member }, $member->{prove}->@* ) if !%more;
    my @given = $member->{environment}->%* ? ( environment => $member->{environment} ) : ();
    my $run   = $engine->run( $project, %settings, $member->{settings}->%*, @given, %more );
    note sprintf '%s=%s: the run took %.1f seconds', $axis, $name, $run->{seconds};
    $runs++;
    $compared += keys $run->{mutants}->%*;
    $ran{"$axis=$name"}++;
    $project->discard;
    my @observed = ( run => $run, member => $member );
    return ( findings( ['I5'], run => $run ),
        map { "$axis=$name: $_" } findings( [ @run, 'I1', 'I7', 'I6' ], @observed ) );
}

my $toolchain = length qx{make --version 2>/dev/null} && length qx{$Config::Config{cc} --version 2>/dev/null};
my @axes      = qw(loading process io taint files path build suite);
my ( @members, @shared, @lone );
for my $axis (@axes) {
    for my $name ( Discovery::Zoo::names($axis) ) {
        my $needs = Discovery::Zoo::needs($name);
        next if defined $needs && !Capability::has( $needs, $toolchain, "the member $name needs a compiler and make" );
        push @members,                                              "$axis=$name";
        push @{ Discovery::Zoo::alone($name) ? \@lone : \@shared }, [ $axis, $name ];
    }
}
for my $axis (@axes) {
    my @together = map { $_->[1] } grep { $_->[0] eq $axis } @shared;
    push $found{fast}->@*, together( $axis, \@together ) if @together;
    push $found{fast}->@*, map { alone( $_->@* ) } grep { $_->[0] eq $axis } @lone;
}

# The pool waits for a test that keeps its output, that closes it, and that sends it elsewhere.
# The turns of the pool during the wait are counted, and no clock is read, so a busy machine changes nothing.
my $waiter = Discovery::Waiter->new;
my %waits  = ( 'close-stdout' => 'closed', 'redirect-stdout' => 'redirected' );
my $kept   = $waiter->waited( 'kept', 1 );
note "the pool turned $kept->{turns} more times for a wait of 1 second with the output kept";
is [ findings( ['I1-wait'], wait => $kept ) ], [], 'the pool waits without turns for a test that keeps its output';
for my $name ( sort keys %waits ) {
    my $wait = $waiter->waited( $waits{$name}, 1 );
    note "process=$name: the pool turned $wait->{turns} more times for a wait of 1 second";
    push $found{fast}->@*, map { "process=$name: $_" } findings( ['I1-wait'], wait => $wait );
}

# The full tier measures each member apart from the others, the loading styles under other settings,
# and the members that change files in the project itself.
# A finding of the fast tier says nothing new there, and each other one names the run it came from.
if ( Discovery::Tier::full() ) {
    my %fast  = map { $_ => 1 } $found{fast}->@*;
    my $fresh = sub ( $label, @found ) {
        return map { "$label, $_" } grep { !$fast{$_} } @found;
    };
    my @styles = map { $_->[1] } grep { $_->[0] eq 'loading' } @shared;
    for my $variant (
        [ 'in the project', in_place => 1 ],
        [ 'file coverage',  coverage => 'file' ],
        [ 'one job',        jobs     => 1 ]
      )
    {
        my ( $label, @more ) = $variant->@*;
        push $found{full}->@*, $fresh->( $label, together( 'loading', \@styles, @more ) );
    }

    # A member apart from the others must show what it shows among them, and no more.
    # A line of the shared runs that no member shows alone came from the company of the others.
    my %apart;
    my @solo = grep { $_->[1] ne $plain } @shared;
    for my $member (@solo) {
        $apart{$_} = 1 for together( $member->[0], [ $member->[1] ], sanity => 0 );
    }

    # The lines of the pool come from the adapter of the pool and from no run of the tool, shared or apart.
    # The adapter names them once more here, so the fast tier stays as the repeated runs measured it.
    my %pooled;
    for my $name ( sort keys %waits ) {
        $pooled{"process=$name: $_"} = 1 for findings( ['I1-wait'], wait => $waiter->waited( $waits{$name}, 1 ) );
    }
    my @labels = map { ( "$_->[0]=$_->[1]: ", "$_->[0]=$plain: ", "$_->[0]: " ) } @shared;
    my @among  = grep {
        my $line = $_;
        !$pooled{$line} && grep { index( $line, $_ ) == 0 } @labels
    } sort keys %fast;
    my $lonely = sub ( $lines, $shown ) {
        return map { "apart, no member alone shows $_" } grep { !$shown->{$_} } $lines->@*;
    };
    push $found{full}->@*, $fresh->( 'apart', sort keys %apart );
    push $found{full}->@*, $lonely->( \@among, \%apart );

    # The comparison counts the members that it measured apart, and it rejects a line that a member loses alone.
    # The number of lines falls as the findings close, so a note states it and no floor holds it.
    note sprintf 'the shared runs gave %d lines to the members apart', scalar @among;
    Gate::checked( 'members apart from the others', scalar @solo, at_least => 57 );
    is [ $lonely->( [ 'process=a: kept', 'process=b: lost' ], { 'process=a: kept' => 1 } ) ],
      ['apart, no member alone shows process=b: lost'], 'a line that no member shows alone is a finding';
    for my $name ( Discovery::Zoo::names('files') ) {
        push $found{full}->@*,
          $fresh->( 'in the project', alone( 'files', $name, in_place => 1, environment => { DISCOVERY_WAIT => 1 } ) );
    }
}

Discovery::Tier::report( 'zoo', \%found );
is [ sort keys %ran ], [ sort @members ], 'every member of every axis ran';
Gate::checked( 'members',            scalar keys %ran, at_least => $toolchain ? 78 : 77 );
Gate::checked( 'runs',               $runs,            at_least => 22 );
Gate::checked( 'mutants in the zoo', $compared,        at_least => 600 );

done_testing;
