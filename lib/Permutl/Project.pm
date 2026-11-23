package Permutl::Project;
use v5.36;
use File::Find             ();
use Types::Standard        qw(ArrayRef Maybe RegexpRef Str);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);

our $VERSION = '0.001';

my %SKIPPED_AT_ROOT = map { $_ => 1 } qw(local blib _build node_modules);

signature_for pattern_regex => ( positional => [Str], returns => RegexpRef );

sub pattern_regex ($pattern) {
    my $regex = q{};
    my @parts = split m{(\*\*/|\*\*|\*|\?)}, $pattern;
    for my $part (@parts) {
        $regex .=
            $part eq '**/' ? '(?:.*/)?'
          : $part eq '**'  ? '.*'
          : $part eq q{*}  ? '[^/]*'
          : $part eq q{?}  ? '[^/]'
          :                  quotemeta $part;
    }
    return qr/\A$regex\z/;
}

sub _static_directory ($pattern) {
    my ($prefix) = $pattern =~ m{\A([^*?]*)/};
    return defined $prefix ? $prefix : q{};
}

signature_for files => (
    positional => [ Str, ArrayRef [Str], ArrayRef [Str] ],
    returns    => ArrayRef [Str],
);

sub files ( $root, $include, $exclude ) {
    my @excluded = map { pattern_regex($_) } $exclude->@*;
    my %found;
    for my $pattern ( $include->@* ) {
        my $regex     = pattern_regex($pattern);
        my $directory = _static_directory($pattern);
        my $start     = length $directory ? "$root/$directory" : $root;
        next if !-d $start;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    if ( -d $File::Find::name ) {
                        my ($name) = $File::Find::name =~ m{([^/]+)\z};
                        my $hidden = $File::Find::name ne $start && $name =~ /\A[.]/;
                        my $vendor = $File::Find::dir eq $root   && $SKIPPED_AT_ROOT{$name};
                        $File::Find::prune = 1 if $hidden || $vendor;
                        return;
                    }
                    my $relative = substr $File::Find::name, length($root) + 1;
                    return if $relative !~ $regex;
                    return if grep { $relative =~ $_ } @excluded;
                    $found{$relative} = 1;
                },
            },
            $start,
        );
    }
    return [ sort keys %found ];
}

signature_for processors => (
    named   => [ cpuinfo => Maybe [Str], sysctl => Maybe [Str] ],
    returns => PositiveInt,
);

sub processors ($arg) {
    my $listed = () = ( defined $arg->cpuinfo ? $arg->cpuinfo : q{} ) =~ /^processor\s*:/mg;
    return $listed if $listed;
    my ($answer) = ( defined $arg->sysctl ? $arg->sysctl : q{} ) =~ /\A([0-9]+)/;
    return $answer ? 0 + $answer : 1;
}

sub _read ( $mode, @source ) {
    open my $handle, $mode, @source or return;
    local $/ = undef;
    my $text = readline $handle;
    close $handle or return;
    return $text;
}

signature_for cpu_count => (
    named   => [ cpuinfo => Str, { default => '/proc/cpuinfo' }, sysctl => Str, { default => '/usr/sbin/sysctl' } ],
    returns => PositiveInt,
);

# A system with the list has a sysctl command without the key, which would write an error for each call.
sub cpu_count ($arg) {
    my $cpuinfo = _read( '<', $arg->cpuinfo );
    my $sysctl  = !defined $cpuinfo && -x $arg->sysctl ? _read( q{-|}, $arg->sysctl, '-n', 'hw.ncpu' ) : undef;
    return processors( cpuinfo => $cpuinfo, sysctl => $sysctl );
}

signature_for default_jobs => ( positional => [PositiveInt], returns => PositiveInt );

sub default_jobs ($processors) {
    return $processors > 1 ? $processors - 1 : 1;
}

1;

__END__

=head1 NAME

Permutl::Project - find the files of a project

=head1 SYNOPSIS

    my $sources = Permutl::Project::files( $root, ['lib/**/*.pm'], [] );

=head1 FUNCTIONS

=head2 pattern_regex

Compiles a glob pattern to a regular expression that matches a whole relative path.
C<*> matches within one path segment, C<?> matches one character, and C<**> matches across segments.

=head2 files

Returns the sorted relative paths under C<$root> that match an include pattern and no exclude pattern.
Hidden directories are skipped, as are C<local>, C<blib>, C<_build>, and C<node_modules> at the root.

=head2 processors

    my $count = Permutl::Project::processors( cpuinfo => $text, sysctl => $answer );

Returns the number of processors that the platform reports.
C<cpuinfo> is the text of F</proc/cpuinfo> and C<sysctl> is the output of C<sysctl -n hw.ncpu>, each undefined when absent.
The function returns 1 when neither names a count.

=head2 cpu_count

Reads C</proc/cpuinfo>, or asks C<sysctl> where that file is missing, and returns what L</processors> finds.
C<cpuinfo> and C<sysctl> name another file and another command.

=head2 default_jobs

Returns the number of test processes for a machine with the given number of processors: one less, and at least one.

=cut
