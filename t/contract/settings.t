use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Fixture qw(copy_of write_file);
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::Config;
use Test::Mutation::Settings;

# S3, the surfaces: every sample of every setting on the command line, in the configuration file, and in a call.
# One setting has one name and one meaning on all three, and each difference of today is an open finding.

my $project = copy_of('calc');
write_file( "$project/ci.toml",    "\n" );
write_file( "$project/empty.toml", "\n" );
my @settings = Test::Mutation::Settings::rows()->@*;
my %violations;

sub violation ( $gate, $what, $setting, $surface ) {
    push $violations{$gate}->@*, [ $what, $setting, $surface ];
    return;
}

# The answer of a surface to what a case says there: the configuration, or the observation of a refusal.
sub answer ( $surface, $said ) {
    return Space::library( $project, $said->@* ) if $surface eq 'library';
    write_file( "$project/case.toml", $said )    if $surface eq 'file';
    my @line        = $surface eq 'file' ? ( '--config', 'case.toml' ) : $said->@*;
    my $observation = World::observe( [ 'list', @line ], cwd => $project, run => 'cheap' );
    die "the plan died: $observation->{died}\n" if defined $observation->{died};
    return $observation->{plan}{refused} ? ( undef, $observation ) : $observation->{plan}{config};
}

subtest 'each sample of each setting on each surface' => sub {
    my $cases = Space::settings();
    my %seen;
    for my $case ( $cases->@* ) {
        my ( $setting, $surface ) = $case->@{qw(setting surface)};
        my ( $config,  $refusal ) = answer( $surface, $case->{said} );
        my $name = $setting->name;
        $seen{surface}{$surface} = $seen{setting}{$name} = $seen{type}{ $setting->type } = 1;

        # The file of settings is no attribute, so a plan that takes it has no value to show.
        # The command resolves the directory of the project to its full path, so its value is no text of a sample.
        my $shown = defined $setting->attribute && $name ne 'root';
        my $text  = !$config ? undef : $shown ? Space::value_text( $setting, $config ) : $case->{sample};
        violation( 'same-config', $_, $name, $surface )
          for Invariants::same_config( $case->{expect}, $case->{sample}, $text );
        next if !$refusal || $surface ne 'file';
        my %symptoms = (
            'one-line'   => [ Invariants::one_line($refusal) ],
            'no-leak'    => [ Invariants::no_leak($refusal) ],
            'typed-name' => [ Invariants::typed_name( $refusal, $setting->key->[1], $setting->attribute ) ],
        );
        for my $gate ( sort keys %symptoms ) {
            violation( $gate, "a value in the file: $_", $name, $surface ) for $symptoms{$gate}->@*;
        }
    }
    my @surfaces = Space::surfaces()->@*;
    is scalar $cases->@*,                Space::settings_count(),             'the cases that the tables call for';
    is [ sort keys $seen{surface}->%* ], [ sort @surfaces ],                  'every surface';
    is [ sort keys $seen{setting}->%* ], [ sort map { $_->name } @settings ], 'every setting';
    is [ sort keys $seen{type}->%* ],    Samples::types(),                    'every type that has samples';
    Gate::checked( 'samples on a surface', scalar $cases->@*, at_least => 150 );
};

subtest 'the default of each setting on each surface' => sub {
    my %config = (
        flag => World::observe( ['list'],                             cwd => $project, run => 'cheap' )->{plan}{config},
        file => World::observe( [ 'list', '--config', 'empty.toml' ], cwd => $project, run => 'cheap' )->{plan}{config},
        library => Space::library($project),
    );
    my $count = 0;
    for my $setting ( grep { defined $_->attribute && $_->attribute ne 'root' } @settings ) {
        for my $surface ( sort keys %config ) {
            my $text = Space::default_text( $setting->kind, $config{$surface}->${ \$setting->attribute } );
            violation( 'same-config', 'the default: another value than the table states', $setting->name, $surface )
              if $text ne $setting->default_text;
            $count++;
        }
    }
    is $count, 3 * ( grep { defined $_->attribute } @settings ) - 3,
      'three surfaces for each attribute but the directory';
};

subtest 'every name that the configuration answers to and that is no setting' => sub {
    my %attribute = map  { $_->attribute => 1 } grep { defined $_->attribute } @settings;
    my @names     = grep { !$attribute{$_} && Test::Mutation::Config->can($_) } sort keys %Test::Mutation::Config::,
      keys %Moo::Object::;
    my @passed = grep { Space::library( $project, $_ => 1 ) } @names;
    violation( 'unknown', 'a call: a name of the configuration class that is no setting passes', 'names', 'library' )
      if @passed;
    is [ grep { Space::library( $project, $_ => 1 ) } qw(nonesuch new from_layers read_file) ], [],
      'a name that the class lacks is refused, and so are the three that the library names';
    Gate::checked( 'names that are no setting', scalar @names, at_least => 10 );
};

for my $setting (@settings) {
    violation( 'one-name',     "names: $_",            $setting->name, 'all' ) for Invariants::one_name($setting);
    violation( 'all-surfaces', 'the surface lacks it', $setting->name, $_ )    for Invariants::all_surfaces($setting);
}

for my $gate (qw(same-config one-line no-leak typed-name unknown one-name all-surfaces)) {
    Gate::findings( "contract-$gate-settings", Space::folded( $violations{$gate} || [], 'settings', 'surfaces' ) );
}

done_testing;
