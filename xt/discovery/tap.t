use v5.36;
use Test2::V0;
use TAP::Parser ();
use lib 't/lib', 'xt/discovery/lib';
use Gate;
use Discovery::Check;
use Discovery::Engine;
use Discovery::Known;
use Discovery::Project;
use Discovery::Reader;
use Discovery::Streams;
use Discovery::Tier;

# The TAP reader of the tool gives the verdict of prove on every stream of a grammar.
# A stream that the reader passes and prove fails hides a detected mutant, and the other direction invents one.

Discovery::Tier::announce();
my $reader = Discovery::Reader->new;
my @single = map { Discovery::Streams::with_choices($_) } 0, 1;
my @pairs  = Discovery::Streams::with_choices(2);
my @checks = ( 'tap', 'tap-prefix', 'tap-pieces' );

subtest 'the oracle rejects a stream that prove fails' => sub {
    my %passes  = map { $_->{label} => Discovery::Reader::oracle( $_->{text}, 0, 0 ) } @single;
    my @passing = (
        qw(version=thirteen version=fourteen version=lower version=after-comment),
        qw(pragma=strict pragma=strict-off pragma=strict-list pragma=strict-bare pragma=ignore-exit),
        qw(plan=last plan=skip-all plan=todo-list plan=skip-all-bare plan=skip-all-text numbers=none numbers=padded),
        qw(result=todo result=todo-lower result=todo-mixed result=todo-tight result=todo-passes),
        qw(result=skip result=skip-lower result=skip-mixed result=escaped-backslash),
        qw(block=yaml block=yaml-open block=yaml-broken block=yaml-short),
        qw(nested=passing nested=inner-fails nested=inner-plan bail=lower),
        qw(garbage=after garbage=before garbage=comment garbage=blank garbage=okay garbage=blank-last),
        qw(ending=crlf final=none),
    );
    is [ grep { $passes{$_} } sort keys %passes ], [ sort @passing, 'the plain stream' ],
      'the streams that prove passes, and it fails every other one';
    is Discovery::Streams::text(), "1..3\nok 1 - first\nok 2 - second\nok 3 - third\n", 'the plain stream';
    is Discovery::Streams::text( plan => 'twice', numbers => 'swapped', ending => 'crlf', final => 'none' ),
      "1..3\r\nok 1 - first\r\nok 3 - second\r\nok 2 - third\r\n1..3", 'a stream with four choices';
    is [
        map { Discovery::Reader::oracle( Discovery::Streams::text(), $_->@* ) } [ 0, 0 ],
        [ 1,   0 ],
        [ 255, 0 ],
        [ 0,   15 ]
      ],
      [ 1, 0, 0, 0 ], 'a failing exit status or a signal fails the plain stream';
    like dies { Discovery::Streams::text( colour => 'red' ) }, qr/\Athe grammar has no axis named colour/,
      'an unknown axis is refused';

    # Version 13 reads another plan and a YAML block, so the same lines get another verdict than under version 12.
    my @under_13 = (
        [ plan   => 'todo-list',     0 ],
        [ plan   => 'skip-text',     1 ],
        [ plan   => 'skip-all-text', 0 ],
        [ block  => 'yaml',          1 ],
        [ block  => 'yaml-bail',     1 ],
        [ block  => 'yaml-open',     0 ],
        [ block  => 'yaml-broken',   0 ],
        [ block  => 'yaml-short',    0 ],
        [ pragma => 'strict',        0 ],
        [ pragma => 'strict-off',    1 ],
        [ pragma => 'strict-list',   0 ],
        [ pragma => 'strict-bare',   1 ],
    );
    for my $case (@under_13) {
        my ( $axis, $value, $passes ) = $case->@*;
        is Discovery::Reader::oracle( Discovery::Streams::text( version => 'thirteen', $axis => $value ), 0, 0 ),
          $passes, "version=thirteen $axis=$value";
    }
    is [ map { Discovery::Reader::oracle( Discovery::Streams::text( version => 'thirteen', pragma => $_ ), 1, 0 ) }
          qw(none strict ignore-exit) ],
      [ 0, 0, 1 ], 'a stream of version 13 that asks for it passes with a failing exit status';
};

# The oracle reads a text, and prove reads a process: both give one verdict where the stream decides the end.
subtest 'the oracle rejects a failing end as the parser of a process does' => sub {
    for my $case ( [ 'none', 0 ], [ 'ignore-exit', 1 ] ) {
        my ( $pragma, $passes ) = $case->@*;
        my $text   = Discovery::Streams::text( version => 'thirteen', pragma => $pragma );
        my $script = sprintf q{print pack 'H*', '%s'; exit 1}, unpack 'H*', $text;
        my $parser = TAP::Parser->new( { exec => [ $^X, '-e', $script ] } );
        $parser->run;
        is $parser->has_problems ? 0 : 1, $passes, "pragma=$pragma: the parser of a process that exits with 1";
        is Discovery::Reader::oracle( $text, 1, 0 ), $passes, "pragma=$pragma: the oracle";
    }
};

# The pool of the tool feeds the reader, and the adapter repeats what the pool does.
# One unmodified run over the streams as test files shows that the adapter and the pool agree.
subtest 'the adapter of the reader stands for the pool of the tool' => sub {
    my $project = Discovery::Project->new;
    Discovery::Known->new( seed => 1, cells => 1, idle => 0, tests => 1 )->write($project);
    $project->remove('t/a.t');
    my @ends = ( [ 0, 0 ], [ 1, 0 ] );
    my ( %fails, $number );
    for my $case (@single) {
        for my $end ( @ends, $case->{parts}->@* ? () : ( [ 255, 0 ], [ 0, 15 ] ) ) {
            my ( $exit, $signal ) = $end->@*;
            my $test = sprintf 't/stream-%03d.t', ++$number;
            $project->write(
                $test,
                sprintf "binmode STDOUT;\n\$| = 1;\nprint pack 'H*', '%s';\n%s\n",
                unpack( 'H*', $case->{text} ),
                $signal ? "kill $signal, \$\$;\nsleep 5;" : "exit $exit;"
            );
            $fails{$test} = "$case->{label} with exit $exit and signal $signal"
              if !$reader->passes( $case->{text}, $exit, $signal );
        }
    }
    my $run = Discovery::Engine->new->run( $project, jobs => 1 );
    is $run->{exit}, 3, 'the unmodified run fails';
    my %failed = map { $_ => $fails{$_} || 'a stream that the adapter passes' } $run->{baseline_failures}->@*;
    is \%failed, \%fails, 'the tool fails the streams that the adapter fails, and no other';
    ok $number >= 142, "the run held $number streams";
};

# The fast tier reads every stream with up to two choices, and the full tier adds the streams with three.
my @triples = Discovery::Tier::full() ? Discovery::Streams::with_choices(3) : ();
my %found   = ( fast => [ Discovery::Check::findings( \@checks, reader => $reader, cases => [ @single, @pairs ] ) ] );
push $found{full}->@*, Discovery::Check::findings( \@checks, reader => $reader, cases => [ @single, @pairs, @triples ] )
  if @triples;
Discovery::Tier::report( 'tap', \%found );

my %ran = map { $_ => 1 } map { $_->{parts}->@* } @single;
my @all;
for my $axis ( Discovery::Streams::axes() ) {
    my ( $plain, @others ) = Discovery::Streams::values_of($axis);
    push @all, map { "$axis=$_" } @others;
}
is [ sort keys %ran ], [ sort @all ], 'every value of every axis has a stream';
Gate::checked( 'axis values',                   scalar @all,     at_least => 69 );
Gate::checked( 'streams with up to one choice', scalar @single,  at_least => 70 );
Gate::checked( 'streams with two choices',      scalar @pairs,   at_least => 2083 );
Gate::checked( 'streams with three choices',    scalar @triples, at_least => Discovery::Tier::full() ? 36_417 : 0 );

done_testing;
