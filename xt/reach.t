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
        my ( $program, @words ) = split q{ }, $command;
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
    my $task = $tasks->{$name} or die "no task is named $name\n";
    my $run  = $task->{run};
    return ( ( map { commands( $tasks, $_, $seen ) } @{ $task->{depends} || [] } ),
        ref $run ? $run->@* : defined $run ? $run : () );
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
    is reached( proves('prove --recurse t'), 't/e2e/a.t' ), 1, 'the long switch walks down too';
    is reached( proves('prove -l txt'),      't/a.t' ),     0, 'a path that only starts alike reaches nothing';

    my %tasks = (
        check => { depends => [ 'test', 'gate' ] },
        test  => { run     => 'prove -lr t/unit' },
        gate  => { run     => [ 'prove -l xt', 'prove -l xt/corpus' ], depends => ['test'] },
    );
    is [ commands( \%tasks, 'check' ) ], [ 'prove -lr t/unit', 'prove -l xt', 'prove -l xt/corpus' ],
      'the commands of a task and of the tasks it depends on, each once';
    like dies { commands( \%tasks, 'chek' ) }, qr/\Ano task is named chek/, 'an unknown task is refused';
};

my ( $data, $error ) = TOML::Tiny::from_toml( slurp('mise.toml') );
die "mise.toml: $error\n" if !defined $data;
my $tasks = $data->{tasks};

# The fast gate runs on every change, and the release gate adds the campaigns that take minutes.
my $fast    = proves( commands( $tasks, 'check' ) );
my $release = proves( commands( $tasks, 'check' ), commands( $tasks, 'mutation-gate' ) );

my $workflow = CPAN::Meta::YAML->read_string( slurp('.github/workflows/check.yml') )->[0];
my $driver   = proves( map { defined $_->{run} ? $_->{run} : () } $workflow->{jobs}{driver}{steps}->@* );

my @tests = grep { !m{\At/(?:fixtures|corpus)/} } map { Library::tests($_)->@* } 't', 'xt';
my @heavy = grep { m{\Axt/(?:corpus|release)/} } @tests;
my @found = (
    (
        map { "$_ is in no task of the fast gate" }
        grep { !reached( $fast, $_ ) } grep { !m{\Axt/(?:corpus|release)/} } @tests
    ),
    ( map { "$_ is in no task of the release gate" } grep { !reached( $release, $_ ) } @heavy ),
    ( map { "$_ is not in the driver job" } grep { !reached( $driver, $_ ) } grep { m{\At/} } @tests ),
);
is \@found, [], 'every test file belongs to a task, and every test of the tool runs on the other interpreters';
Gate::checked( 'test files',                 scalar @tests,      at_least => 60 );
Gate::checked( 'commands of the fast gate',  scalar $fast->@*,   at_least => 4 );
Gate::checked( 'commands of the driver job', scalar $driver->@*, at_least => 1 );
Gate::checked( 'tests of the release gate',  scalar @heavy,      at_least => 2 );

done_testing;
