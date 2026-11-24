use v5.36;
use Test2::V0;
use List::Util qw(min);
use POSIX      ();
use lib 't/lib';
use Gate;
use Test::Mutation::Project;

# Experiment E13: what a container with a processor limit shows to a process inside it.
# The fixtures hold the texts of real containers, for the count of processors that reads them later.
# The test states what each text says, so a parser has the answers next to its inputs.

my $FIXTURES = 't/unit/fixtures/processors';

sub text ($path) {
    open my $handle, '<', "$FIXTURES/$path" or die "read $path: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!";
    return $text;
}

sub directories ($kind) {
    opendir my $handle, "$FIXTURES/$kind" or die "read $kind: $!";
    my @names = sort grep { !/\A[.]/ } readdir $handle;
    closedir $handle or die "close $kind: $!";
    return @names;
}

# The whole processors that cover a quota of processor time, or nothing for a group without a quota.
sub quota ( $quota, $period ) {
    die "no quota: $quota\n"   if $quota  !~ /\A(?:max|-1|[1-9][0-9]*)\z/;
    die "no period: $period\n" if $period !~ /\A[1-9][0-9]*\z/;
    return $quota =~ /\A(?:max|-1)\z/ ? undef : POSIX::ceil( $quota / $period );
}

# The number of processors in a list such as 0,2,4-5.
sub listed ($list) {
    my $count = 0;
    for my $range ( split /,/, $list, -1 ) {
        my ( $first, $last ) = $range =~ /\A([0-9]+)(?:-([0-9]+))?\z/ or die "no range: $range\n";
        $count += ( defined $last ? $last : $first ) - $first + 1;
    }
    return $count;
}

subtest 'the readers of the test reject a text of another shape' => sub {
    is quota( '200000', '100000' ), 2,     'a quota of two periods';
    is quota( '150000', '100000' ), 2,     'a quota of one and a half periods needs two processors';
    is quota( 'max',    '100000' ), undef, 'no quota in version 2';
    is quota( '-1',     '100000' ), undef, 'no quota in version 1';
    like dies { quota( 'fast',   '100000' ) }, qr/\Ano quota: fast/, 'a quota that is no number';
    like dies { quota( '200000', '0' ) },      qr/\Ano period: 0/,   'a period of zero';
    is listed('0-17'),    18, 'one range';
    is listed('0,2,4-5'), 4,  'single processors and a range';
    like dies { listed('0-') },   qr/\Ano range: 0-/, 'an open range';
    like dies { listed('0,,2') }, qr/\Ano range: /,   'an empty member';
};

# What each recorded container was started with, and what its texts say.
my %RECORDED = (
    'unlimited'   => { switches => q{},                  cpu_max => 'max 100000',     quota => undef, affinity => 18 },
    'quota-2'     => { switches => '--cpus 2 ',          cpu_max => '200000 100000',  quota => 2,     affinity => 18 },
    'quota-1.5'   => { switches => '--cpus 1.5 ',        cpu_max => '150000 100000',  quota => 2,     affinity => 18 },
    'quota-0.5'   => { switches => '--cpus 0.5 ',        cpu_max => '50000 100000',   quota => 1,     affinity => 18 },
    'cpuset-0-1'  => { switches => '--cpuset-cpus 0-1 ', cpu_max => 'max 100000',     quota => undef, affinity => 2 },
    'cpuset-list' => { switches => '--cpuset-cpus 0,2,4-5 ', cpu_max => 'max 100000', quota => undef, affinity => 4 },
    'cpuset-and-quota' =>
      { switches => '--cpuset-cpus 0-3 --cpus 2 ', cpu_max => '200000 100000', quota => 2, affinity => 4 },
    'period-50000' =>
      { switches => '--cpu-period 50000 --cpu-quota 150000 ', cpu_max => '150000 50000', quota => 3, affinity => 18 },
);

my $cpuinfo = text('cpuinfo');
my $online  = 18;
is scalar( () = $cpuinfo =~ /^processor\t: [0-9]+$/mg ), $online, 'the list of the platform names every processor';
my $counted = Test::Mutation::Project::processors( cpuinfo => $cpuinfo, sysctl => undef );

is [ directories('recorded') ], [ sort keys %RECORDED ], 'every recorded container has its answers here';
my ( %ignored, $checked );
for my $name ( sort keys %RECORDED ) {
    my $says = $RECORDED{$name};
    is text("recorded/$name/command"), "docker run $says->{switches}perl:5.36\n",
      "$name: the switches of the container";

    my $cpu_max = text("recorded/$name/cpu.max");
    is $cpu_max, "$says->{cpu_max}\n",                "$name: cpu.max holds the quota and the period in microseconds";
    is quota( split q{ }, $cpu_max ), $says->{quota}, "$name: the processors that the quota allows";

    my ($allowed) = text("recorded/$name/status") =~ /^Cpus_allowed_list:\t(\S+)$/m;
    ok defined $allowed, "$name: the status of a process has a line with the list of its processors";
    is listed($allowed),                             $says->{affinity}, "$name: the processors of the affinity";
    is text("recorded/$name/cpuset.cpus.effective"), "$allowed\n", "$name: the cpuset of the group holds the same list";
    is text("recorded/$name/nproc"),  "$says->{affinity}\n", "$name: nproc follows the affinity and not the quota";
    is text("recorded/$name/online"), "$online\n",           "$name: the online count follows neither";
    is text("recorded/$name/cgroup"), "0::/\n", "$name: the process sees the root of a version 2 hierarchy";

    my $may_run = min( $online, $says->{affinity}, defined $says->{quota} ? $says->{quota} : () );
    $ignored{'quota of a container'}    = 1 if defined $says->{quota}      && $counted > $may_run;
    $ignored{'affinity of the process'} = 1 if $says->{affinity} < $online && $counted > $may_run;
    $checked++;
}

# Nobody recorded these, and each one names the documents that it follows.
my %CONSTRUCTED = ( 'cgroup-v1-quota-2' => 2, 'cgroup-v1-unlimited' => undef );
is [ directories('constructed') ], [ sort keys %CONSTRUCTED ], 'every constructed text has its answer here';
for my $name ( sort keys %CONSTRUCTED ) {
    like text("constructed/$name/source"), qr/^No machine at hand mounted a cgroup version 1 hierarchy/,
      "$name: the directory says that its texts are constructed";
    ok !-e "$FIXTURES/constructed/$name/command", "$name: and it names no container";
    my ( $quota, $period ) = map { text("constructed/$name/$_") =~ s/\n\z//r } 'cpu.cfs_quota_us', 'cpu.cfs_period_us';
    is quota( $quota, $period ), $CONSTRUCTED{$name}, "$name: the processors that the quota allows";
    like text("constructed/$name/cgroup"), qr/\A[1-9][0-9]*:[a-z,]*\bcpu\b[a-z,]*:\/\S*\n\z/,
      "$name: the process sees a version 1 hierarchy with the cpu controller";
    $checked++;
}

# The count of today reads the list of the platform alone.
is $counted, $online, 'the count of the tool is the online count in every container';
Gate::findings( 'processors', [ map { "the processor count ignores the $_" } sort keys %ignored ] );
Gate::checked( 'containers and constructed groups', $checked, at_least => 10 );

done_testing;
