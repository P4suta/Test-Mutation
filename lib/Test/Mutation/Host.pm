package Test::Mutation::Host;
use v5.36;
use List::Util             qw(min);
use POSIX                  ();
use Types::Standard        qw(ArrayRef Dict Enum HashRef Maybe Str);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);

our $VERSION = '0.001';

# The usual mount point of the control groups, where systemd and the container engines put them.
my $HIERARCHIES = '/sys/fs/cgroup';

# The files that hold the quota of a group, by the version of its hierarchy.
# Version 2 holds "$MAX $PERIOD" in one file, and version 1 holds the two numbers in two files.
my %QUOTA_FILES = ( 1 => [qw(cpu.cfs_quota_us cpu.cfs_period_us)], 2 => ['cpu.max'] );

# The sources of a count from the widest to the narrowest, so that a tie names the wider one.
my @SOURCES = qw(online affinity quota);
my %PHRASE  = (
    online   => 'online',
    affinity => 'in the affinity of the process',
    quota    => 'in the quota of the control group',
    none     => 'by default',
);

my $COUNT = Dict [ count => PositiveInt, source => Enum [ sort keys %PHRASE ] ];

# The list format of cpuset(7): single numbers and ranges between commas, such as 0-3,8.
sub _listed ($list) {
    my $count = 0;
    for my $range ( split /,/, $list, -1 ) {
        my ( $first, $last ) = $range =~ /\A([0-9]+)(?:-([0-9]+))?\z/ or return;
        $last = $first if !defined $last;
        return if $last < $first;
        $count += $last - $first + 1;
    }
    return $count;
}

sub _affinity ($status) {
    my ($list) = ( defined $status ? $status : q{} ) =~ /^Cpus_allowed_list:\s*(\S+)$/m;
    return defined $list ? scalar _listed($list) : undef;
}

sub _online ( $cpuinfo, $sysctl ) {
    my $listed = () = ( defined $cpuinfo ? $cpuinfo : q{} ) =~ /^processor\s*:/mg;
    return $listed if $listed;
    my ($answer) = ( defined $sysctl ? $sysctl : q{} ) =~ /\A([0-9]+)/;
    return $answer ? 0 + $answer : undef;
}

# A quota and a period in microseconds make the whole processors that the quota fills.
# max in version 2 and -1 in version 1 mean no limit, and neither is a positive number.
sub _limit (@words) {
    return if @words != 2 || grep { !/\A[1-9][0-9]*\z/ } @words;
    my ( $quota, $period ) = @words;
    return POSIX::ceil( $quota / $period );
}

# A group and every group above it, since the quota of a parent bounds its children.
sub _ancestors ($path) {
    my @paths = (q{});
    push @paths, "$paths[-1]/$_" for grep { length } split m{/}, $path;
    return reverse @paths;
}

# Each line of /proc/self/cgroup holds an identifier, a list of controllers, and a path.
# The list is empty for version 2, and a hierarchy of version 1 counts when its list names the cpu controller.
# Each group comes back as the paths of its quota files.
sub _groups ($cgroup) {
    my @groups;
    for my $line ( split /\n/, defined $cgroup ? $cgroup : q{} ) {
        my ( $controllers, $path ) = $line =~ /\A[0-9]+:([^:]*):(\/.*)\z/ or next;
        next if length $controllers && !grep { $_ eq 'cpu' } split /,/, $controllers;
        my $mount = join q{/}, grep { length } $HIERARCHIES, $controllers;
        my $files = $QUOTA_FILES{ length $controllers ? 1 : 2 };
        for my $directory ( map { "$mount$_" } _ancestors($path) ) {
            push @groups, [ map { "$directory/$_" } $files->@* ];
        }
    }
    return @groups;
}

sub _quota ( $cgroup, $texts ) {
    my @limits = grep { defined }
      map {
        _limit( map { split q{ }, defined $texts->{$_} ? $texts->{$_} : q{} } $_->@* )
      } _groups($cgroup);
    return @limits ? min(@limits) : undef;
}

signature_for files => ( positional => [ Maybe [Str] ], returns => ArrayRef [Str] );

sub files ($cgroup) {
    return [ map { $_->@* } _groups($cgroup) ];
}

signature_for count => (
    named => [
        status  => Maybe [Str],
        cgroup  => Maybe [Str],
        quotas  => HashRef [ Maybe [Str] ],
        cpuinfo => Maybe [Str],
        sysctl  => Maybe [Str],
    ],
    returns => $COUNT,
);

sub count ($arg) {
    my %limit = (
        online   => _online( $arg->cpuinfo, $arg->sysctl ),
        affinity => _affinity( $arg->status ),
        quota    => _quota( $arg->cgroup, $arg->quotas ),
    );
    my @known = grep { defined $limit{$_} } @SOURCES;
    return { count => 1, source => 'none' } if !@known;
    my $least = min @limit{@known};
    my ($source) = grep { $limit{$_} == $least } @known;
    return { count => $least, source => $source };
}

signature_for describe => ( positional => [$COUNT], returns => Str );

sub describe ($count) {
    my $noun = $count->{count} == 1 ? 'processor' : 'processors';
    return "$count->{count} $noun $PHRASE{ $count->{source} }";
}

sub _read ( $mode, @source ) {
    open my $handle, $mode, @source or return;
    local $/ = undef;
    my $text = readline $handle;
    close $handle or return;
    return $text;
}

signature_for processors => (
    named   => [ root => Str, { default => q{} }, sysctl => Str, { default => '/usr/sbin/sysctl' } ],
    returns => $COUNT,
);

# A system with /proc/cpuinfo has a sysctl command without the key, which would write an error for each call.
sub processors ($arg) {
    my $root    = $arg->root;
    my $cgroup  = _read( '<', "$root/proc/self/cgroup" );
    my $cpuinfo = _read( '<', "$root/proc/cpuinfo" );
    my $status  = _read( '<', "$root/proc/self/status" );
    my $sysctl  = !defined $cpuinfo && -x $arg->sysctl ? _read( q{-|}, $arg->sysctl, '-n', 'hw.ncpu' ) : undef;
    my %quotas  = map { $_ => scalar _read( '<', "$root$_" ) } files($cgroup)->@*;
    return count( status => $status, cgroup => $cgroup, quotas => \%quotas, cpuinfo => $cpuinfo, sysctl => $sysctl );
}

1;

__END__

=head1 NAME

Test::Mutation::Host - count the processors that a run may use

=head1 SYNOPSIS

    my $count = Test::Mutation::Host::processors();
    say Test::Mutation::Host::describe($count);    # 2 processors in the quota of the control group

    my $files = Test::Mutation::Host::files("0::/\n");
    my $same  = Test::Mutation::Host::count(
        status  => "Cpus_allowed_list:\t0-17\n",
        cgroup  => "0::/\n",
        quotas  => { '/sys/fs/cgroup/cpu.max' => "200000 100000\n" },
        cpuinfo => undef,
        sysctl  => "18\n",
    );

=head1 DESCRIPTION

A run may use the least of three counts: the processors online, the affinity of the process, and the quota of its control group.
The functions read texts, and L</processors> alone reads the files of the platform.

The online count comes from the processor lines of F</proc/cpuinfo>, or from C<sysctl -n hw.ncpu> where that file is missing.
The affinity comes from the line C<Cpus_allowed_list> of F</proc/self/status>.
The quota comes from the group that F</proc/self/cgroup> names and from every group above it, and the least one counts.
Version 2 keeps a quota in F<cpu.max> under F</sys/fs/cgroup>.
Version 1 keeps it in F<cpu.cfs_quota_us> and F<cpu.cfs_period_us>, in the directory under F</sys/fs/cgroup> that bears the names of its controllers.
A quota counts the whole processors that it fills, so half a processor counts as one.
A text that the functions cannot read limits nothing.

=head1 FUNCTIONS

=head2 files

Returns the paths of the files that hold the quotas for the text of F</proc/self/cgroup>, from the group of the process up to the root.

=head2 count

Returns the count and its source from the texts of the platform.
C<status> is the text of F</proc/self/status>, C<cgroup> the text of F</proc/self/cgroup>, and C<quotas> the texts of the paths that L</files> names.
C<cpuinfo> is the text of F</proc/cpuinfo> and C<sysctl> the output of C<sysctl -n hw.ncpu>.
An undefined text stands for a file that the platform lacks.

The count is the least of the known counts, and one where none is known.
The source is C<online>, C<affinity>, C<quota>, or C<none>, and a tie names the first of these.

=head2 describe

Returns the words that name a count and its source, such as C<2 processors in the quota of the control group>.

=head2 processors

Reads the files of the platform and returns what L</count> makes of them.
C<root> names a directory that stands for the root of the file system, and C<sysctl> names another command.

=cut
