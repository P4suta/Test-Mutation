use v5.36;
use Test2::V0;
use CPAN::Meta::YAML ();
use TOML::Tiny       ();
use lib 't/lib';
use Gate;
use Library;

# A test file that no task runs checks nothing.
# The gate reads the tasks and the workflow, and it names every test file that none of their prove commands reaches.

# The prove commands of a list of shell commands, each as its paths and whether it walks into directories.
sub proves (@commands) {
    my @proves;
    for my $command (@commands) {
        my ( $program, @words ) = split q{ }, $command =~ s/\Aperl\s+-S\s+//r;
        next if !defined $program || $program ne 'prove';
        my @switches = grep { /\A-/ } @words;
        push @proves,
          {
            paths     => [ grep { !/\A-/ } @words ],
            recursive => ( grep { /\A-[[:alpha:]]*r|\A--recurse\z/ } @switches ) ? 1 : 0
          };
    }
    return \@proves;
}

sub reached ( $proves, $file ) {
    for my $prove ( $proves->@* ) {
        for my $path ( $prove->{paths}->@* ) {
            return 1 if $path eq $file;
            my ($below) = $file =~ m{\A\Q$path\E/(.*)\z} or next;
            return 1 if $prove->{recursive} || $below !~ m{/};
        }
    }
    return 0;
}

# The commands of a task and of every task it depends on.
sub commands ( $tasks, $name, $seen = {} ) {
    return if $seen->{$name}++;
    my $task     = $tasks->{$name} or die "no task is named $name\n";
    my $run      = $task->{run};
    my @commands = map { commands( $tasks, $_, $seen ) } @{ $task->{depends} || [] };
    for my $command ( ref $run ? @$run : defined $run ? ($run) : () ) {
        my ($nested) = $command =~ /\Amise run ([\w-]+)\z/;
        push @commands, defined $nested ? commands( $tasks, $nested, $seen ) : $command;
    }
    return @commands;
}

sub slurp ($path) {
    open my $handle, '<:encoding(UTF-8)', $path or die "read $path: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return $text;
}

subtest 'the gate rejects a test file that no command reaches' => sub {
    my $proves =
      proves( 'prove -lr t/unit t/assumptions', 'prove -l xt', 'perl -Ilib bin/mutation', 'prove -l xt/corpus/a.t' );
    is $proves,
      [
        { paths => [ 't/unit', 't/assumptions' ], recursive => 1 },
        { paths => ['xt'],                        recursive => 0 },
        { paths => ['xt/corpus/a.t'],             recursive => 0 },
      ],
      'the prove commands with their paths';
    is [ map { reached( $proves, $_ ) }
          qw(t/unit/a.t t/unit/deep/a.t t/assumptions/a.t xt/a.t xt/corpus/a.t xt/corpus/b.t xt/deep/a.t t/e2e/a.t) ],
      [ 1, 1, 1, 1, 1, 0, 0, 0 ],
      'a recursive command walks down, another one reads its own directory, and a named file counts';
    is reached( proves('prove --recurse t'),   't/e2e/a.t' ),  1, 'the long switch walks down too';
    is reached( proves('prove -l txt'),        't/a.t' ),      0, 'a path that only starts alike reaches nothing';
    is reached( proves('perl -S prove -lr t'), 't/unit/a.t' ), 1, 'the selected Perl runs prove';
    is proves('perl -S cpm install prove'), [], 'another program cannot claim test coverage';

    my %tasks = (
        check => { depends => [ 'test', 'gate' ] },
        test  => { run     => 'prove -lr t/unit' },
        gate  => { run     => [ 'prove -l xt', 'prove -l xt/corpus' ], depends => ['test'] },
    );
    is [ commands( \%tasks, 'check' ) ], [ 'prove -lr t/unit', 'prove -l xt', 'prove -l xt/corpus' ],
      'the commands of a task and of the tasks it depends on, each once';
    $tasks{'release-gate'} = { run => [ 'mise run check', 'mise run discovery', 'mise run check' ] };
    $tasks{discovery}      = { run => 'prove -l xt/discovery' };
    is [ commands( \%tasks, 'release-gate' ) ],
      [ 'prove -lr t/unit', 'prove -l xt', 'prove -l xt/corpus', 'prove -l xt/discovery' ],
      'a release reaches exactly the commands of its invoked tasks';
    $tasks{'release-gate'}{run} = ['mise run absent'];
    like dies { commands( \%tasks, 'release-gate' ) }, qr/no task is named absent/,
      'a missing nested task cannot claim test coverage';
    like dies { commands( \%tasks, 'chek' ) }, qr/\Ano task is named chek/, 'an unknown task is refused';
};

my ( $data, $error ) = TOML::Tiny::from_toml( slurp('mise.toml') );
die "mise.toml: $error\n" if !defined $data;
my $tasks = $data->{tasks};

# The fast gate runs on every change, and the release gate adds the campaigns that take minutes.
# The runs on real distributions need a container, so a task of their own belongs to the release gate.
my $HEAVY   = qr{\Axt/(?:install|mutants|release|realworld)/};
my $fast    = proves( commands( $tasks, 'check' ) );
my $release = proves( commands( $tasks, 'release-gate' ) );

my $workflow = CPAN::Meta::YAML->read_string( slurp('.github/workflows/check.yml') )->[0];
is [ sort keys $workflow->{on}->%* ], [qw(merge_group pull_request)],
  'the fast checks run for pull requests and merge queues';
my $gate_job = $workflow->{jobs}{gate};
my @groups   = map { [ commands( $tasks, $_->{task} ) ] } @{ $gate_job->{strategy}{matrix}{include} || [] };
my @hosted   = map { $_->@* } @groups;
my @local    = commands( $tasks, 'check' );
is [ sort @hosted ], [ sort @local ], 'the hosted jobs run every local fast check exactly once';
is scalar( grep { $_->@* == 1 && $_->[0] eq $tasks->{e2e}{run} } @groups ), 1,
  'the end-to-end tests have a runner to themselves';
ok scalar( grep { defined $_->{run} && $_->{run} eq 'mise run ${{ matrix.task }}' } $gate_job->{steps}->@* ),
  'each hosted job runs its assigned task';
my $distribution = CPAN::Meta::YAML->read_string( slurp('.github/workflows/release-gate.yml') )->[0];
is [ sort keys $distribution->{on}->%* ], ['workflow_dispatch'], 'the release checks run on manual dispatch';
my @mac     = grep { $_->{'runs-on'} =~ /\Amacos-/ } values $distribution->{jobs}->%*;
my @install = grep {
    my %steps = map { $_->{run} => 1 } grep { defined $_->{run} } $_->{steps}->@*;
    $steps{'mise run dist'} && $steps{'mise x -- make disttest'}
} @mac;
ok scalar @install, 'a macOS job builds and tests the unpacked distribution';

my $driver = proves( map { defined $_->{run} ? $_->{run} : () } $workflow->{jobs}{driver}{steps}->@* );

my @tests = grep { !m{\At/(?:fixtures|corpus)/} } map { Library::tests($_)->@* } 't', 'xt';
my @heavy = grep { $_ =~ $HEAVY } @tests;
my @found = (
    ( map { "$_ is in no task of the fast gate" } grep { !reached( $fast, $_ ) } grep { $_ !~ $HEAVY } @tests ),
    ( map { "$_ is in no task of the release gate" } grep { !reached( $release, $_ ) } @heavy ),
    ( map { "$_ is not in the driver job" } grep { !reached( $driver, $_ ) } grep { m{\At/} } @tests ),
);
is \@found, [], 'every test file belongs to a task, and every test of the tool runs on the other interpreters';
Gate::checked( 'test files',                 scalar @tests,      at_least => 60 );
Gate::checked( 'commands of the fast gate',  scalar $fast->@*,   at_least => 4 );
Gate::checked( 'commands of the driver job', scalar $driver->@*, at_least => 1 );
Gate::checked( 'tests of the release gate',  scalar @heavy,      at_least => 3 );

done_testing;
