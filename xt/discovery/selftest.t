use v5.36;
use Test2::V0;
use lib 't/lib', 'xt/discovery/lib';
use Gate;
use Discovery::Check;
use Discovery::Engine;
use Discovery::Known;
use Discovery::Project;
use Discovery::Reader;
use Discovery::Saboteur;
use Discovery::Streams;
use Discovery::Zoo;

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

# Two loading styles that the tool serves alike, so every difference between them comes from a saboteur.
my $zoo     = Discovery::Zoo->new( known => $known );
my $styles  = Discovery::Project->new;
my $built   = $zoo->build( $styles, 'use', 'require' );
my @between = ( known => $known, member => $built->{require}, reference => $built->{use} );

$bench{I8} = sub ($engine) {
    return [ Discovery::Check::findings( ['I8'], run => $engine->run( $styles, equivalence => 0 ), @between ) ];
};

# The bench gives one style a lost kill that a warning names, which is how the tool reports a deviation.
$bench{I6} = sub ($engine) {
    my $reporting = $engine->before(
        sub ( $run, $settings ) {
            my ($id) = grep { $run->{mutants}{$_}{path} eq 'lib/Zoo/Require.pm' && $run->{status}{$_} eq 'Killed' }
              sort keys $run->{status}->%*;
            $run->{status}{$id} = 'NoCoverage';
            push $run->{warnings}->@*, 't/require.t loads lib/Zoo/Require.pm around the hook';
        }
    );
    return [ Discovery::Check::findings( ['I6'], run => $reporting->run( $styles, equivalence => 0 ), @between ) ];
};

# The checks of the reader take the adapter of the reader in place of the adapter of the engine.
my $reader  = Discovery::Reader->new;
my @streams = map { Discovery::Streams::with_choices($_) } 0, 1;
my %subject = ( 'tap' => $reader, 'tap-prefix' => $reader );
for my $name ( sort keys %subject ) {
    $bench{$name} = sub ($adapter) {
        return [ Discovery::Check::findings( [$name], reader => $adapter, cases => \@streams ) ];
    };
}

is [ sort keys %bench ],             [ Discovery::Check::names() ], 'every check has a bench';
is [ Discovery::Saboteur::names() ], [ Discovery::Check::names() ], 'the saboteur set equals the invariant set';

my $saboteurs = 0;
for my $name ( Discovery::Check::names() ) {
    subtest "the check $name rejects its saboteurs" => sub {
        my $subject  = $subject{$name} || $honest;
        my %accepted = map { $_ => 1 } $bench{$name}->($subject)->@*;
        my $kinds    = Discovery::Saboteur::of($name);
        ok scalar keys $kinds->%*, 'the check has a saboteur';
        for my $kind ( sort keys $kinds->%* ) {
            my @rejected = grep { !$accepted{$_} } $bench{$name}->( $kinds->{$kind}->($subject) )->@*;
            Discovery::Saboteur::undo();
            ok scalar @rejected, "$kind is rejected"
              or diag 'the check found nothing more than with the honest adapter';
            note "$kind: $_" for @rejected;
            $saboteurs++;
        }
        is [ sort grep { !$accepted{$_} } $bench{$name}->($subject)->@* ], [],
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
