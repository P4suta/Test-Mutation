use v5.36;
use Test2::V0;
use Config         qw(%Config);
use Cwd            ();
use File::Basename ();
use File::Path     ();
use File::Spec     ();
use File::Temp     ();
use JSON::PP       ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;

sub read_text ($path) {
    open my $handle, '<:raw', $path or die "read $path: $!";
    local $/ = undef;
    my $text = readline $handle;
    close $handle or die "close $path: $!";
    return $text // q{};
}

my $archive = $ENV{TEST_MUTATION_DISTRIBUTION};
unless ( defined $archive ) {
    my $meta = JSON::PP->new->decode( read_text('MYMETA.json') );
    $archive = "$meta->{name}-$meta->{version}.tar.gz";
}
bail_out("build the distribution archive $archive with mise run dist") unless -f $archive;
$archive = Cwd::abs_path($archive);
my ($installer) = grep { -f && -x _ } map { "$_/cpanm" } File::Spec->path;
bail_out('cpanm is required to install the distribution') unless defined $installer;
$installer = Cwd::abs_path($installer);
my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $prefix  = "$scratch/install";
my $project = "$scratch/project";
File::Path::make_path( $project, "$scratch/home", "$scratch/tmp" );
my $bin         = File::Basename::dirname( Cwd::abs_path($^X) );
my %environment = (
    PATH            => join( $Config{path_sep}, "$prefix/bin", $bin, qw(/usr/bin /bin /usr/sbin /sbin) ),
    HOME            => "$scratch/home",
    PERL5LIB        => "$prefix/lib/perl5",
    PERL_CPANM_HOME => "$scratch/cpanm",
    TMPDIR          => "$scratch/tmp",
    LC_ALL          => 'C',
);

sub run_in_project (@command) {
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ( !$pid ) {
        local %ENV = %environment;
        chdir $project or die "enter $project: $!";
        open STDOUT, '>:raw', "$scratch/command.log" or die "redirect standard output: $!";
        open STDERR, '>&',    \*STDOUT               or die "redirect standard error: $!";
        exec { $command[0] } @command or die "start $command[0]: $!";
    }
    waitpid( $pid, 0 ) == $pid or die "wait for the installed command: $!";
    die "command ended on signal " . ( $? & 127 ) if $? & 127;
    return $? >> 8;
}

sub addition () {
    my $doc     = JSON::PP->new->utf8->decode( read_text("$project/mutation-report/mutation.json") );
    my @entries = grep { $_->{mutatorName} eq 'arithmetic' } $doc->{files}{'lib/Totals.pm'}{mutants}->@*;
    is scalar @entries, 1, 'the report identifies the changed addition';
    return $entries[0];
}

my $effective_home = q{my $home = $ENV{HOME} // (getpwuid $<)[7]; print $home if -d $home && -w _};
my $home_status    = run_in_project( $^X, '-e', $effective_home );
is [ $home_status, read_text("$scratch/command.log") ], [ 0, "$scratch/home" ],
  'the installer and its subprocesses use a private home directory'
  or bail_out('the home directory is not isolated');
my $installed = run_in_project( $^X, $installer, '--from', 'https://cpan.metacpan.org', '-L', $prefix, $archive );
if ($installed) {
    diag read_text("$scratch/command.log");
    if ( -f "$scratch/cpanm/build.log" ) {
        my @lines = split /\n/, read_text("$scratch/cpanm/build.log");
        diag join "\n", @lines[ ( @lines > 80 ? @lines - 80 : 0 ) .. $#lines ];
    }
    bail_out("the clean installation exited with $installed");
}
my $command = "$prefix/bin/mutation";
ok -x $command, 'the distribution installed its executable in the fresh prefix';
my $origins = <<'PERL';
use Test::Mutation;
use Cpanel::JSON::XS;
use DBI;
use DBD::SQLite;
print "$INC{$_}\n" for qw(Test/Mutation.pm Cpanel/JSON/XS.pm DBI.pm DBD/SQLite.pm);
PERL
is run_in_project( $^X, '-e', $origins ), 0, 'the installed driver loads its JSON and database modules'
  or diag read_text("$scratch/command.log");
my @origins = split /\n/, read_text("$scratch/command.log");
is scalar @origins, 4, 'each required module reports its path';
like $_, qr{\A\Q$prefix/\E}, 'the temporary installation supplies the module' for @origins;

subtest 'the installed command rejects a test gap and confirms its repair' => sub {
    write_file( "$project/lib/Totals.pm", "package Totals;\nsub sum { return \$_[0] + \$_[1] }\n1;\n" );
    write_file( "$project/t/sum.t",       "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 0), 4;\n" );
    my @options = ( '--format', 'json', '--jobs', 1, '--min-score', 100 );
    is run_in_project( $command, 'run', @options ), 1, 'the original assertion misses the threshold'
      or diag read_text("$scratch/command.log");
    my $miss = addition();
    is $miss->{testMutation}{status}, 'Survived', 'the original test accepts subtraction';
    write_file( "$project/t/positive.t", "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 1), 5;\n" );
    is run_in_project( $command, 'run', '--undetected', @options ), 0,
      'the stronger suite passes the threshold for the previously missed change'
      or diag read_text("$scratch/command.log");
    my $detected = addition();
    is [ $detected->{id}, $detected->{testMutation}{status}, $detected->{killedBy} ],
      [ $miss->{id}, 'Killed', ['t/positive.t'] ], 'the added assertion detects the same mutant';
};

Gate::checked(
    'modules loaded from the installation',
    scalar grep( { index( $_, "$prefix/" ) == 0 } @origins ),
    at_least => 3
);
done_testing;
