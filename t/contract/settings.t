use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Fixture qw(write_file);
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::Config;
use Test::Mutation::Settings;

# S3, the surfaces: every sample of every setting on the command line, in the configuration file, and in a call.

my $project = Space::tree();
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
    my $observation = World::observe( [ 'run', @line ], cwd => $project, run => 'cheap' );
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
        $seen{surface}{$surface} = $seen{setting}{$name} = $seen{type}{ $setting->type->name } = 1;

        # The command resolves the directory of the project to its full path, so its value is no text of a sample.
        my $text = !$config ? undef : $name ne 'root' ? Space::value_text( $setting, $config ) : $case->{sample};
        violation( 'same-config', $_, $name, $surface )
          for Invariants::same_config( $case->{expect}, $case->{sample}, $text );
        next if !$refusal || $surface ne 'file';
        my %symptoms = (
            'one-line'   => [ Invariants::one_line($refusal) ],
            'no-leak'    => [ Invariants::no_leak($refusal) ],
            'typed-name' => [ Invariants::typed_name( $refusal, $setting->key, $setting->attribute ) ],
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
    my $declared = Space::declared_defaults( {} );
    my $count    = 0;

    # Each surface reaches the defaults through the directory and the file, so neither of the two has a default to show.
    for my $setting ( grep { $_->group ne 'project' } @settings ) {
        my $expected = exists $declared->{ $setting->attribute } ? $declared->{ $setting->attribute } : q{};
        for my $surface ( sort keys %config ) {
            violation( 'same-config', 'the default: another value than the table states', $setting->name, $surface )
              if Space::value_text( $setting, $config{$surface} ) ne $expected;
            $count++;
        }
    }
    is $count, 3 * ( @settings - 2 ), 'three surfaces for each setting but the directory and the file';
};

subtest 'every name that the configuration answers to and that is no setting' => sub {
    my %attribute = map  { $_->attribute => 1 } @settings;
    my @names     = grep { !$attribute{$_} && Test::Mutation::Config->can($_) } sort keys %Test::Mutation::Config::,
      keys %Moo::Object::;
    my @passed = grep { Space::library( $project, $_ => 1 ) } @names;
    violation( 'unknown', 'a call: a name of the configuration class that is no setting passes', 'names', 'library' )
      if @passed;
    is [ grep { Space::library( $project, $_ => 1 ) } qw(nonesuch new resolve of_call) ], [],
      'a name that the class lacks is refused, and so are the names of the functions that build it';
    Gate::checked( 'names that are no setting', scalar @names, at_least => 10 );
};

# A surface answers to one name of a setting: the name of another surface and a setting that the surface lacks are refused.
subtest 'each surface refuses the names of the other surfaces' => sub {
    my $count = 0;
    for my $setting (@settings) {
        my ( $name, $call, $kind ) = ( $setting->name, $setting->attribute, $setting->kind );
        my $sample = Space::samples($setting)->{valid}[0];
        my $value  = Samples::toml( Samples::type( $setting->type->name ), $sample );
        my $wrote  = $kind eq 'list' ? "[$value]" : $value;
        my $given  = $kind eq 'list' ? [$sample]  : $sample;
        my @valued = $kind eq 'flag' ? ()         : ($sample);

        # The name of the call on the command line and in the file, and the name of the file in a call.
        my %other =
          $call eq $name
          ? ()
          : (
            flag    => [ "--$call", @valued ],
            file    => "$call = $wrote\n",
            library => [ $name, $given ],
          );
        my %absent = (
            ( $setting->offers('line') ? () : ( flag    => [ $setting->flag, @valued ] ) ),
            ( $setting->offers('file') ? () : ( file    => "$name = $wrote\n" ) ),
            ( $setting->offers('call') ? () : ( library => [ $call, $given ] ) ),
        );
        for my $surface ( sort keys %other ) {
            my ($config) = answer( $surface, $other{$surface} );
            violation( 'one-name', 'a surface takes the name of another surface', $name, $surface ) if $config;
            $count++;
        }
        for my $surface ( sort keys %absent ) {
            my ($config) = answer( $surface, $absent{$surface} );
            violation( 'all-surfaces', 'a surface takes a setting that the table leaves off it', $name, $surface )
              if $config;
            $count++;
        }
    }
    Gate::checked( 'names of other surfaces', $count, at_least => 30 );
};

# The settings of the contract that the plan of the tool states, each with its default in the words of the table.
my %CONTRACT = (
    root                      => q{.},
    config                    => 'mutation.toml when it exists',
    source                    => 'lib/**/*.pm and the Perl scripts of bin and script',
    'source-exclude'          => 'none',
    test                      => 't/**/*.t',
    'test-exclude'            => 'none',
    perl                      => 'the running interpreter',
    lib                       => 'lib, or blib for a distribution that builds',
    switch                    => 'none',
    profile                   => 'default',
    enable                    => 'none',
    disable                   => 'none',
    since                     => 'none',
    mutant                    => 'none',
    undetected                => 'off',
    shard                     => 'none',
    jobs                      => 'one less than the processors, and at least one',
    coverage                  => 'line',
    'timeout-factor'          => '4',
    'timeout-floor'           => '10',
    'baseline-timeout'        => '600',
    equivalence               => 'on',
    'in-place'                => 'off',
    cache                     => 'on',
    'keep-work'               => 'off',
    link                      => 'local',
    'cache-dir'               => '.mutation',
    'report-dir'              => 'mutation-report',
    format                    => 'terminal json html',
    'min-score'               => 'none',
    'threshold-high'          => '80',
    'threshold-low'           => '60',
    github                    => 'on inside GitHub Actions',
    color                     => 'on for a terminal without NO_COLOR',
    'suppress-require-names'  => 'off',
    'suppress-require-reason' => 'off',
);
my %row  = map { $_->name => $_ } @settings;
my @plan = (
    ( map { "the table lacks the setting $_ of the contract" } grep { !$row{$_} } sort keys %CONTRACT ),
    (
        map  { "the table holds the setting $_, which the contract lacks" }
        grep { !exists $CONTRACT{$_} } sort keys %row
    ),
    (
        map  { "the default of $_ differs from the contract" }
        grep { $row{$_} && $row{$_}->default_text ne $CONTRACT{$_} } sort keys %CONTRACT
    ),
);
Gate::findings( 'contract-plan-settings', \@plan );

my %SURFACE = ( line => 'flag', file => 'file', call => 'library' );
for my $setting (@settings) {
    violation( 'one-name', "names: $_", $setting->name, 'all' )
      for Invariants::one_name( $setting->flag, $setting->key, $setting->attribute );
    violation( 'all-surfaces', 'the surface lacks it', $setting->name, $_ )
      for Invariants::all_surfaces( $setting->name, [ map { $SURFACE{$_} } $setting->surfaces->@* ] );
}

for my $gate (qw(same-config one-line no-leak typed-name unknown one-name all-surfaces)) {
    Gate::findings( "contract-$gate-settings", Space::folded( $violations{$gate} || [], 'settings', 'surfaces' ) );
}

done_testing;
