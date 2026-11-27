use v5.36;
use Test2::V0;
use File::Path qw(make_path);
use File::Temp ();
use lib 't/lib';
use Capability;
use Test::Mutation::Host;

# The count of processors is the least of the online count, the affinity, and the quota of the control group.
# Each case gives the texts of a platform, and the files of the control groups by their paths.

my $V2       = '/sys/fs/cgroup';
my $CPUINFO  = join q{}, map { "processor\t: $_\nmodel name\t: A\n\n" } 0 .. 7;
my $ALLOWED  = "Name:\tperl\nCpus_allowed:\tff\nCpus_allowed_list:\t%s\n";
my %NOTHING  = ( status => undef, cgroup => undef, quotas => {}, cpuinfo => undef, sysctl => undef );
my %EIGHT    = ( %NOTHING, cpuinfo => $CPUINFO );
my %IN_GROUP = ( %EIGHT,   cgroup  => "0::/\n" );

sub counted (%text) {
    return Test::Mutation::Host::count( %NOTHING, %text );
}

sub limited ( $count, $source ) {
    return { count => $count, source => $source };
}

subtest 'the online count comes from the list of the platform or from sysctl' => sub {
    my $listed = join "\n", "processor\t: 0", 'model name : A', 'Processor : B', "processor\t: 1", 'processor: 2', q{};
    my @cases  = (
        [ 'the processor lines of cpuinfo',         $listed,            undef,   3 ],
        [ 'cpuinfo before sysctl',                  $listed,            "8\n",   3 ],
        [ 'sysctl when cpuinfo is absent',          undef,              "8\n",   8 ],
        [ 'sysctl when cpuinfo lists no processor', "model name : A\n", "12\n",  12 ],
        [ 'one processor',                          undef,              "1\n",   1 ],
        [ 'a number with a suffix',                 undef,              "4 x\n", 4 ],
    );
    for my $case (@cases) {
        my ( $name, $text, $answer, $expected ) = $case->@*;
        is counted( cpuinfo => $text, sysctl => $answer ), limited( $expected, 'online' ), $name;
    }
    my @unknown = (
        [ 'no source',                 undef, undef ],
        [ 'a count of zero',           undef, "0\n" ],
        [ 'text without a number',     undef, "none\n" ],
        [ 'a number after other text', undef, "x 4\n" ],
        [ 'an empty answer',           undef, q{} ],
    );
    for my $case (@unknown) {
        my ( $name, $text, $answer ) = $case->@*;
        is counted( cpuinfo => $text, sysctl => $answer ), limited( 1, 'none' ), "$name: one processor by default";
    }
};

subtest 'the affinity comes from the list of allowed processors in the status of the process' => sub {
    my @cases = (
        [ 'one range',                     '0-3',     4 ],
        [ 'single processors',             '1,5',     2 ],
        [ 'single processors and a range', '0,2,4-5', 4 ],
        [ 'a range of one',                '6-6',     1 ],
        [ 'a range away from zero',        '2-4',     3 ],
        [ 'every processor',               '0-7',     8 ],
    );
    for my $case (@cases) {
        my ( $name, $list, $expected ) = $case->@*;
        is counted( %EIGHT, status => sprintf $ALLOWED, $list ),
          limited( $expected, $expected < 8 ? 'affinity' : 'online' ), "$name: $list";
    }
    for my $list ( '0-', '3-1', '0,,2', 'a-b', '-1', '0-3,', ',0' ) {
        is counted( %EIGHT, status => sprintf $ALLOWED, $list ), limited( 8, 'online' ),
          "a list that the format of cpuset(7) refuses limits nothing: $list";
    }
    is counted( %EIGHT, status => "Cpus_allowed:\t3\n" ), limited( 8, 'online' ), 'the mask alone limits nothing';
    is counted( %EIGHT, status => "Name:\tperl\nCpus_allowed_list: 0-1\nMems_allowed_list:\t0\n" ),
      limited( 2, 'affinity' ), 'a space after the colon, and a line after the list';
    is counted( %EIGHT, status => "Other_Cpus_allowed_list:\t0\n" ), limited( 8, 'online' ),
      'the name of the line starts the line';
};

subtest 'a quota counts the whole processors that it fills in each period' => sub {
    my @version_2 = (
        [ "max 100000\n",      undef ],
        [ "200000 100000\n",   2 ],
        [ "150000 100000\n",   2 ],
        [ "50000 100000\n",    1 ],
        [ "100000 100000\n",   1 ],
        [ "100001 100000\n",   2 ],
        [ "700000 100000\n",   7 ],
        [ "150000 50000\n",    3 ],
        [ "200000 100000",     2 ],
        [ "200000\n",          undef ],
        [ "0 100000\n",        undef ],
        [ "200000 0\n",        undef ],
        [ "-200000 100000\n",  undef ],
        [ "2e5 100000\n",      undef ],
        [ "200000 100000 3\n", undef ],
        [ q{},                 undef ],
    );
    for my $case (@version_2) {
        my ( $text, $quota ) = $case->@*;
        is counted( %IN_GROUP, quotas => { "$V2/cpu.max" => $text } ),
          defined $quota ? limited( $quota, 'quota' ) : limited( 8, 'online' ), 'cpu.max ' . ( $text =~ s/\n/\\n/r );
    }

    my $mount     = "$V2/cpu,cpuacct";
    my %in_v1     = ( %EIGHT, cgroup => "4:cpu,cpuacct:/\n" );
    my @version_1 = (
        [ "-1\n",     "100000\n", undef ],
        [ "200000\n", "100000\n", 2 ],
        [ "250000\n", "100000\n", 3 ],
        [ "10000\n",  "50000\n",  1 ],
        [ "200000\n", undef,      undef ],
        [ undef,      "100000\n", undef ],
        [ "200000\n", "0\n",      undef ],
    );
    for my $case (@version_1) {
        my ( $quota, $period, $expected ) = $case->@*;
        my %files = ( "$mount/cpu.cfs_quota_us" => $quota, "$mount/cpu.cfs_period_us" => $period );
        is counted( %in_v1, quotas => \%files ),
          defined $expected ? limited( $expected, 'quota' ) : limited( 8, 'online' ),
          join ' over ', map { defined $_ ? s/\n//r : 'nothing' } $quota, $period;
    }
};

subtest 'the files of the quota follow the lines of /proc/self/cgroup up to the root of each hierarchy' => sub {
    my @cases = (
        [ 'version 2 at its root', "0::/\n", ["$V2/cpu.max"] ],
        [
            'version 2 in a nested group',
            "0::/user.slice/session-1.scope\n",
            [ "$V2/user.slice/session-1.scope/cpu.max", "$V2/user.slice/cpu.max", "$V2/cpu.max" ]
        ],
        [
            'version 1 with the cpu controller',
            "4:cpu,cpuacct:/docker/abc\n",
            [
                map { ( "$_/cpu.cfs_quota_us", "$_/cpu.cfs_period_us" ) } "$V2/cpu,cpuacct/docker/abc",
                "$V2/cpu,cpuacct/docker", "$V2/cpu,cpuacct"
            ]
        ],
        [
            'version 1 with the controllers of cgroups(7)',
            "5:cpuacct,cpu,cpuset:/daemons\n",
            [
                map { ( "$_/cpu.cfs_quota_us", "$_/cpu.cfs_period_us" ) } "$V2/cpuacct,cpu,cpuset/daemons",
                "$V2/cpuacct,cpu,cpuset"
            ]
        ],
        [
            'both versions on one host',
            "12:memory:/x\n4:cpu,cpuacct:/\n1:name=systemd:/x\n0::/x\n",
            [ "$V2/cpu,cpuacct/cpu.cfs_quota_us", "$V2/cpu,cpuacct/cpu.cfs_period_us", "$V2/x/cpu.max", "$V2/cpu.max" ]
        ],
        [ 'a hierarchy of version 1 without the cpu controller', "3:cpuset:/\n2:cpuacct:/\n1:name=systemd:/\n", [] ],
        [ 'a path with a colon',        "0::/a:b\n",                [ "$V2/a:b/cpu.max", "$V2/cpu.max" ] ],
        [ 'a line of another shape',    "0:/\nx::/\n0::relative\n", [] ],
        [ 'a line without its newline', '0::/',                     ["$V2/cpu.max"] ],
        [ 'no file',                    undef,                      [] ],
    );
    for my $case (@cases) {
        my ( $name, $cgroup, $files ) = $case->@*;
        is Test::Mutation::Host::files($cgroup), $files, $name;
    }
};

subtest 'the quota of a parent bounds its children' => sub {
    my $nested = "0::/a/b\n";
    my @cases  = (
        [ 'the group itself',  { "$V2/a/b/cpu.max" => "200000 100000\n", "$V2/a/cpu.max" => "max 100000\n" },    2 ],
        [ 'its parent',        { "$V2/a/b/cpu.max" => "max 100000\n",    "$V2/a/cpu.max" => "300000 100000\n" }, 3 ],
        [ 'the least of both', { "$V2/a/b/cpu.max" => "500000 100000\n", "$V2/a/cpu.max" => "300000 100000\n" }, 3 ],
        [
            'the least, the other way',
            { "$V2/a/b/cpu.max" => "300000 100000\n", "$V2/a/cpu.max" => "500000 100000\n" }, 3
        ],
    );
    for my $case (@cases) {
        my ( $name, $files, $expected ) = $case->@*;
        is counted( %EIGHT, cgroup => $nested, quotas => $files ), limited( $expected, 'quota' ), $name;
    }
    my %v1 =
      map { ( "$V2/cpu,cpuacct$_/cpu.cfs_quota_us" => "-1\n", "$V2/cpu,cpuacct$_/cpu.cfs_period_us" => "100000\n" ) }
      '/docker/abc', '/docker', q{};
    $v1{"$V2/cpu,cpuacct/cpu.cfs_quota_us"} = "400000\n";
    is counted( %EIGHT, cgroup => "4:cpu,cpuacct:/docker/abc\n", quotas => \%v1 ), limited( 4, 'quota' ),
      'a container of version 1 sees its own group at the root of the mount';
    is counted(
        %EIGHT,
        cgroup => "4:cpu,cpuacct:/\n0::/\n",
        quotas => { %v1, "$V2/cpu.max" => "200000 100000\n" }
      ),
      limited( 2, 'quota' ), 'the least quota of two hierarchies';
};

subtest 'the count is the least of the three, and a tie names the wider source' => sub {
    my $status = sprintf $ALLOWED, '0-3';
    my @cases  = (
        [ 'nothing limits',               {},                                                limited( 8, 'online' ) ],
        [ 'the affinity',                 { status => $status },                             limited( 4, 'affinity' ) ],
        [ 'the quota',                    { quota => "300000 100000\n" },                    limited( 3, 'quota' ) ],
        [ 'the quota below the affinity', { status => $status, quota => "200000 100000\n" }, limited( 2, 'quota' ) ],
        [ 'the affinity below the quota', { status => $status, quota => "500000 100000\n" }, limited( 4, 'affinity' ) ],
        [ 'a tie of affinity and quota',  { status => $status, quota => "400000 100000\n" }, limited( 4, 'affinity' ) ],
        [ 'a tie of online and quota',    { quota => "800000 100000\n" },                    limited( 8, 'online' ) ],
        [ 'a quota above the online count',     { quota => "1600000 100000\n" },             limited( 8, 'online' ) ],
        [ 'an affinity above the online count', { status => sprintf $ALLOWED, '0-15' },      limited( 8, 'online' ) ],
    );
    for my $case (@cases) {
        my ( $name, $given, $expected ) = $case->@*;
        my %quotas = defined $given->{quota} ? ( "$V2/cpu.max" => $given->{quota} ) : ();
        is counted( %IN_GROUP, status => $given->{status}, quotas => \%quotas ), $expected, $name;
    }
    is counted( status => $status ), limited( 4, 'affinity' ), 'the affinity without an online count';
    is counted( cgroup => "0::/\n", quotas => { "$V2/cpu.max" => "200000 100000\n" } ), limited( 2, 'quota' ),
      'the quota without an online count';
};

subtest 'the words name the count and its source' => sub {
    my @cases = (
        [ limited( 18, 'online' ),   '18 processors online' ],
        [ limited( 2,  'affinity' ), '2 processors in the affinity of the process' ],
        [ limited( 2,  'quota' ),    '2 processors in the quota of the control group' ],
        [ limited( 1,  'quota' ),    '1 processor in the quota of the control group' ],
        [ limited( 1,  'none' ),     '1 processor by default' ],
    );
    for my $case (@cases) {
        my ( $count, $words ) = $case->@*;
        is Test::Mutation::Host::describe($count), $words, $words;
    }
};

# A directory stands for the root of the file system, with the files of a platform in place.
sub platform (%file) {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    for my $path ( sort keys %file ) {
        my ($directory) = $path =~ m{\A(.*)/};
        make_path("$root/$directory");
        open my $handle, '>', "$root/$path" or die "write $path: $!";
        print {$handle} $file{$path} or die "write $path: $!";
        close $handle                or die "close $path: $!";
    }
    return $root;
}

subtest 'processors reads the files of the platform' => sub {
    my $root = platform(
        'proc/cpuinfo'                => $CPUINFO,
        'proc/self/status'            => sprintf( $ALLOWED, '0-5' ),
        'proc/self/cgroup'            => "0::/job\n",
        'sys/fs/cgroup/job/cpu.max'   => "300000 100000\n",
        'sys/fs/cgroup/cpu.max'       => "100000 100000\n",
        'sys/fs/cgroup/other/cpu.max' => "100000 100000\n",
    );
    is Test::Mutation::Host::processors( root => $root, sysctl => "$root/none" ), limited( 1, 'quota' ),
      'the quota of the group and of the root of its hierarchy';
    my $free = platform( 'proc/cpuinfo' => $CPUINFO, 'proc/self/status' => sprintf( $ALLOWED, '0-5' ) );
    is Test::Mutation::Host::processors( root => $free, sysctl => "$free/none" ), limited( 6, 'affinity' ),
      'the affinity where the platform has no control groups';
    my $empty = platform();
    is Test::Mutation::Host::processors( root => $empty, sysctl => "$empty/none" ), limited( 1, 'none' ),
      'a platform without a file and without sysctl';
};

subtest 'processors runs sysctl only where the list of processors is missing' => sub {
    my $listed  = platform( 'proc/cpuinfo' => "processor\t: 0\nmodel\t: a\n\nprocessor\t: 1\nmodel\t: a\n" );
    my $missing = platform();
    my $command = "$missing/sysctl";
    open my $handle, '>', $command or die "write: $!";

    # The echo of dash takes -n for its own option, so the command writes its arguments with printf.
    print {$handle} "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> $missing/asked\necho 8\n" or die "write: $!";
    close $handle                                                                   or die "close: $!";
    chmod 0755, $command or die "chmod: $!";

    is Test::Mutation::Host::processors( root => $listed, sysctl => $command ), limited( 2, 'online' ),
      'the list gives the count';
    ok !-e "$missing/asked", 'and the command stays quiet, because it knows no such key on a system with the list';
    is Test::Mutation::Host::processors( root => $missing, sysctl => $command ), limited( 8, 'online' ),
      'without the list the command answers';
    is [
        do { open my $asked, '<', "$missing/asked" or die "read: $!"; readline $asked }
      ],
      ["-n hw.ncpu\n"],
      'with the key of the online count';
};

subtest 'processors asks the platform' => sub {
    my ($online) = qx{getconf _NPROCESSORS_ONLN 2>/dev/null} =~ /\A([1-9][0-9]*)\n\z/;
    Capability::need( 'processor-count', defined $online, 'getconf reports no processor count' );
    my $count = Test::Mutation::Host::processors();
    ok $count->{count} <= $online, "never more than the $online processors online";
    is $count->{count}, $online, 'and all of them where nothing else limits the run' if $count->{source} eq 'online';
};

subtest 'arguments are checked' => sub {
    like dies { Test::Mutation::Host::count( %NOTHING, cpuinfo => [] ) }, qr/did not pass type constraint/,
      'a text is a string';
    like dies { Test::Mutation::Host::count( %NOTHING, quotas => { a => [] } ) }, qr/did not pass type constraint/,
      'and so is the text of each quota file';
    like dies { Test::Mutation::Host::count( cpuinfo => undef ) }, qr/Wrong number of parameters/,
      'every text is named';
    like dies { Test::Mutation::Host::files( [] ) }, qr/did not pass type constraint/, 'files takes a text';
    like dies { Test::Mutation::Host::describe( limited( 0, 'online' ) ) }, qr/did not pass type constraint/,
      'a count is positive';
    like dies { Test::Mutation::Host::describe( limited( 2, 'guess' ) ) }, qr/did not pass type constraint/,
      'and its source is known';
};

done_testing;
