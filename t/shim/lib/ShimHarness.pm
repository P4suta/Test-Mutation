package ShimHarness;
use strict;
use warnings;
use Cwd        ();
use File::Path ();
use File::Temp ();
use Exporter 'import';

our @EXPORT_OK = qw(project write_file write_spec run_perl records all_records lib_dir);

sub lib_dir { return Cwd::abs_path('lib') }

sub project {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    File::Path::mkpath("$root/records");
    return $root;
}

sub write_file {
    my ( $path, $content ) = @_;
    my ($dir) = $path =~ m{\A(.*)/[^/]+\z};
    File::Path::mkpath($dir) if defined $dir && !-d $dir;
    open my $handle, '>', $path or die "write $path: $!";
    binmode $handle;
    print {$handle} $content or die "print $path: $!";
    close $handle            or die "close $path: $!";
    return $path;
}

sub write_spec {
    my ( $path, %spec ) = @_;
    my @lines = ( "trace\t" . ( $spec{trace} ? 1 : 0 ) );
    push @lines, join "\t", 'target', @{$_} for @{ $spec{targets} };
    return write_file( $path, join q{}, map { "$_\n" } @lines );
}

sub run_perl {
    my (%run) = @_;
    my $root  = $run{root};
    my $out   = "$root/stdout.txt";
    my $err   = "$root/stderr.txt";
    my $pid   = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        chdir $root or die "chdir $root: $!";
        my %extra = %{ $run{env} || {} };
        my @outer = _outer_switches();
        $extra{PERL5OPT} = join q{ }, grep { defined && length } $ENV{PERL5OPT},   $extra{PERL5OPT};
        $extra{PERL5LIB} = join q{:}, grep { defined && length } $extra{PERL5LIB}, $ENV{PERL5LIB};
        %ENV             = ( %ENV, %extra, OUTER_HOOKS => scalar grep { ref } @INC );
        open STDOUT, '>', $out or die "stdout: $!";
        open STDERR, '>', $err or die "stderr: $!";
        exec {$^X} $^X, @outer, @{ $run{args} } or die "exec: $!";
    }
    waitpid $pid, 0;
    return { status => $? >> 8, stdout => _slurp($out), stderr => _slurp($err) };
}

sub all_records {
    my ($root) = @_;
    my @lines;
    for my $file ( sort glob "$root/records/*.rec" ) {
        push @lines, grep { length } split /\n/, _slurp($file);
    }
    return [ map { [ split /\t/, $_, -1 ] } @lines ];
}

# Perl loads command-line modules before the ones in PERL5OPT.
# An outer run must load its shim first, so its switches go to the front of the command line.
sub _outer_switches {
    return if !defined $ENV{TEST_MUTATION_GENERATION};
    my @directories = grep { length } split /:/,  defined $ENV{PERL5LIB} ? $ENV{PERL5LIB} : q{};
    my @modules     = grep { length } split q{ }, defined $ENV{PERL5OPT} ? $ENV{PERL5OPT} : q{};
    return ( ( map { "-I$_" } @directories ), @modules );
}

sub records {
    my ($root) = @_;
    return [ grep { $_->[0] ne 'begin' } @{ all_records($root) } ];
}

sub _slurp {
    my ($path) = @_;
    open my $handle, '<', $path or return q{};
    local $/ = undef;
    my $content = <$handle>;
    close $handle or die "close $path: $!";
    return defined $content ? $content : q{};
}

1;
