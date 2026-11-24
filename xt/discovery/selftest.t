use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/discovery/lib';
use Gate;
use Discovery::Check;
use Discovery::Engine;
use Discovery::Known;
use Discovery::Project;
use Discovery::Saboteur;

# A check that accepts every input finds nothing for the wrong reason.
# Each invariant and each relation therefore meets its saboteurs: adapters that break it and that the check must reject.

my $honest  = Discovery::Engine->new( memo => {} );
my $known   = Discovery::Known->new( seed => 1, cells => 3, tests => 1 );
my $project = Discovery::Project->new;
$known->write($project);

# The bench of a check drives an adapter the way the harness of the check does.
sub single ($name) {
    return sub ($engine) {
        my $run = $engine->run($project);
        return [ Discovery::Check::findings( [$name], run => $run, known => $known, coverage => 'line' ) ];
    };
}

my %bench = map { $_ => single($_) } qw(completes I2 I3 I4 I5 I7);

is [ sort keys %bench ],             [ Discovery::Check::names() ], 'every check has a bench';
is [ Discovery::Saboteur::names() ], [ Discovery::Check::names() ], 'the saboteur set equals the invariant set';

my $saboteurs = 0;
for my $name ( Discovery::Check::names() ) {
    subtest "the check $name rejects its saboteurs" => sub {
        my %accepted = map { $_ => 1 } $bench{$name}->($honest)->@*;
        my $kinds    = Discovery::Saboteur::of($name);
        ok scalar keys $kinds->%*, 'the check has a saboteur';
        for my $kind ( sort keys $kinds->%* ) {
            my @rejected = grep { !$accepted{$_} } $bench{$name}->( $kinds->{$kind}->($honest) )->@*;
            Discovery::Saboteur::undo();
            ok scalar @rejected, "$kind is rejected"
              or diag 'the check found nothing more than with the honest adapter';
            note "$kind: $_" for @rejected;
            $saboteurs++;
        }
        is [ sort grep { !$accepted{$_} } $bench{$name}->($honest)->@* ], [],
          'the honest adapter passes again after the damage is undone';
    };
}

subtest 'the honest run is no empty observation' => sub {
    my $run = $honest->run($project);
    is [ $run->@{qw(exit signal hung reported)} ], [ 0, 0, 0, 1 ], 'the tool measured the project';
    ok scalar keys $run->{mutants}->%* >= 6, 'the project has mutants';
    is [ sort keys $run->{status}->%* ],        [ sort keys $run->{mutants}->%* ], 'every mutant has a status';
    is [ $run->@{qw(left changed processes)} ], [ [], [], [] ],                    'the run leaves nothing behind';
    is [ sort keys $run->{tests}->%* ],         ['t/a.t'],                         'the run names its tests';
};

subtest 'the adapter rejects a setting that it cannot pass on' => sub {
    like dies { $honest->run( $project, parallel => 2 ) }, qr/\Athe adapter has no setting named parallel/,
      'an unknown setting';
};

Gate::checked( 'checks',    scalar Discovery::Check::names(), at_least => 6 );
Gate::checked( 'saboteurs', $saboteurs,                       at_least => 12 );

done_testing;
