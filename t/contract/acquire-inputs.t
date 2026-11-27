use v5.36;
use Test2::V0;
use Cwd            ();
use Errno          ();
use File::Basename ();
use File::Temp     ();
use IO::Select     ();
use POSIX          ();
use Symbol         ();
our $faults;    ## no critic (Variables::ProhibitPackageVars)

sub _open : prototype(*;$@) {    ## no critic (Subroutines::RequireArgUnpacking)
                                 # Aliasing the caller handle lets open initialize a lexical handle.
    if ( $faults && $faults->{probe_pipe} && caller eq 'Test::Mutation::Select' && $_[1] eq '-|' ) {
        $! = Errno::EMFILE();    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return;
    }
    if ( defined $_[0] && !ref $_[0] ) {
        return CORE::open( Symbol::qualify_to_ref( $_[0], scalar caller ), $_[1], @_[ 2 .. $#_ ] );
    }
    return CORE::open( $_[0], $_[1], @_[ 2 .. $#_ ] ) if @_ > 2;
    return CORE::open( $_[0], $_[1] ) if @_ == 2;
    return CORE::open( $_[0] );
}

sub _sysread : prototype(*\$;$) {    ## no critic (Subroutines::RequireArgUnpacking)
                                     # The prototype passes the destination buffer by reference.
    my $fd = $faults && caller eq 'Test::Mutation::Git' ? fileno $_[0] : undef;
    die "Git did not finish reading its pipes\n" if defined $fd && ++$faults->{reads} > 1000;
    my $error = defined $fd ? shift $faults->{read_errors}->@* : undef;
    my $count;
    if ($error) {
        $! = $error;                 ## no critic (Variables::RequireLocalizedPunctuationVars)
    }
    else {
        $count = @_ == 4 ? CORE::sysread( $_[0], ${ $_[1] }, $_[2], $_[3] ) : CORE::sysread( $_[0], ${ $_[1] }, $_[2] );
    }
    if ( defined $fd ) {
        $faults->{finished}{$fd} = 1              if defined $count ? !$count : $! != Errno::EINTR();
        $!                       = Errno::EINTR() if defined $count && $faults->{stale_errno};          ## no critic (Variables::RequireLocalizedPunctuationVars)
    }
    return $count;
}

sub _waitpid : prototype($$) ( $pid, $flags ) {
    if ( $faults && caller eq 'Test::Mutation::Git' ) {
        die "Git did not finish both pipes before waiting\n" unless keys $faults->{finished}->%* == 2;
        die "Git waited after reaping its child\n" if ++$faults->{waits} > 10;
        if ( my $error = shift $faults->{wait_errors}->@* ) {
            CORE::waitpid( $pid, $flags ) if $error == Errno::ECHILD();
            $! = $error;    ## no critic (Variables::RequireLocalizedPunctuationVars)
            return -1;
        }
    }
    my $waited = CORE::waitpid( $pid, $flags );
    if ( $faults && caller eq 'Test::Mutation::Git' && $waited == $pid ) {
        $faults->{reaped}++;
        $faults->{finished} = {};
    }
    $! = Errno::EINTR() if $faults && $faults->{stale_errno} && caller eq 'Test::Mutation::Git';    ## no critic (Variables::RequireLocalizedPunctuationVars)
    return $waited;
}

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::open    = \&_open;
    *CORE::GLOBAL::sysread = \&_sysread;
    *CORE::GLOBAL::waitpid = \&_waitpid;
}

use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Capability;
use Fixture qw(ran write_file);
use Raised;
use World;
use Test::Mutation::Git;
use Test::Mutation::Settings;
use Test::Mutation::Select;

my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
write_file( "$project/lib/Addition.pm", 'package Addition; sub sum { $_[0] + $_[1] } 1;' );
my $output = "$project/reports";
mkdir $output or die $!;

sub config (%settings) {
    return Test::Mutation::Settings::of_call( { root => $project, report_dir => 'reports', %settings } );
}

sub checked ( $config, $summary = undef ) {
    my $dirname = \&File::Basename::dirname;
    no warnings 'redefine';
    local *File::Basename::dirname = sub ($path) {
        my $parent = $dirname->($path);
        die "the report directory search continued past its root\n" if $parent eq $path;
        return $parent;
    };
    return Test::Mutation::Select::outputs( $config, $summary );
}

sub refused ($code) {
    my $error = Raised::error($code);
    return ref $error ? $error->[1] : $error;
}

subtest 'a child that cannot execute the interpreter terminates at the version probe' => sub {
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ( !$pid ) {
        Test::Mutation::Select::_print_version("$project/missing-version-probe");    ## no critic (Subroutines::ProtectPrivateSubs)
        POSIX::_exit(92);
    }
    waitpid $pid, 0;
    is $? >> 8, 127, 'a failed exec cannot return into the driver';
};

subtest 'the usable report destinations are checked before a test starts' => sub {
    my $json    = config( format => ['json'] );
    my $html    = config( format => ['html'] );
    my $summary = config( format => [], github => 1 );
    mkdir "$output/mutation.json" or die $!;
    is refused( sub { checked($json) } ), 'file-unwritable', 'a directory cannot be a JSON report';
    is checked($html),                    undef,             'a format that was left out needs no usable destination';
    rmdir "$output/mutation.json" or die $!;
    symlink 'missing', "$output/mutation.html" or die $!;
    is refused( sub { checked($html) } ), 'file-unwritable', 'a dangling link cannot receive an HTML report';
    is checked($json),                    undef,             'the usable JSON destination remains independent';
    unlink "$output/mutation.html" or die $!;
    is refused( sub { checked( $summary, 'lib/Addition.pm/summary' ) } ), 'file-unwritable',
      'a regular file cannot be the parent of a job summary';
    is checked( $summary, 'reports/summary' ),            undef, 'a writable parent can receive a new summary';
    is refused( sub { checked( $summary, 'reports' ) } ), 'file-unwritable', 'a job summary must be a file';
    is checked( config( format => ['terminal'], github => 0 ), 'lib/Addition.pm/summary' ), undef,
      'a disabled job summary leaves its destination alone';
    is checked( $summary, undef ), undef, 'the job can run without a summary destination';
    is checked( $summary, q{} ),   undef, 'an empty destination leaves the job summary unwritten';
    symlink 'reports', "$project/valid" or die $!;
    is checked( config( format => ['json'], report_dir => 'valid/nested' ) ), undef,
      'an existing directory link is usable';
    symlink 'missing', "$project/broken" or die $!;
    is refused( sub { checked( config( format => ['json'], report_dir => 'broken/nested' ) ) } ),
      'directory-uncreatable', 'a broken directory link stops the search for a parent';
    my $original = \&File::Basename::dirname;
    my $calls    = 0;
    {
        no warnings 'redefine';
        local *File::Basename::dirname = sub ($path) {
            die "no existing ancestor found\n" if ++$calls > 32;
            return $original->($path);
        };
        is checked( config( format => ['json'], report_dir => 'new/nested/reports' ) ), undef,
          'the search stops at an existing ancestor';
    }
    return if !Capability::has( 'unprivileged', $> != 0, 'the access checks need an unprivileged account' );
    for my $mode ( map { oct } qw(500 600) ) {
        chmod $mode, $output or die $!;
        is refused( sub { checked($json) } ), 'directory-uncreatable',               "a report parent with mode $mode";
        is refused( sub { checked( $summary, 'reports/new' ) } ), 'file-unwritable', "a summary parent with mode $mode";
        chmod 0700, $output or die $!;
    }
    my $path = write_file( "$output/mutation.json", "prior report\n" );
    chmod 0400, $path or die $!;
    is refused( sub { checked($json) } ), 'file-unwritable', 'a read-only report is left intact';
    chmod 0600, $path or die $!;
    is checked($json), undef, 'an existing writable report can be refreshed';
};

subtest 'the library resolves the actual root and checks the executable before acquiring resources' => sub {
    my $select = sub (%settings) { Test::Mutation::Select::resolve( config => config(%settings) ) };
    my $alias  = "$project/alias";
    symlink $project, $alias or die $!;
    is $select->( root => $alias )->project, $project, 'the selection identifies the physical directory';
    is refused( sub { $select->( root => "$project/absent" ) } ), 'directory-closed', 'a missing library root';
    my $path = write_file( "$project/program", "#!$^X\nprint q{5.040};\n" );
    chmod 0700, $path or die $!;
    is refused( sub { $select->( root => $path ) } ), 'directory-closed',
      'an executable file cannot be the project root';
    is refused( sub { $select->( perl => 'reports' ) } ), 'interpreter-invalid', 'the interpreter must be a program';
    my $selected = $select->( perl => './program' );
    is $selected->perl, $path, 'the selected interpreter can be relative to the project';
    {
        local $faults = { probe_pipe => 1 };
        is refused( sub { $select->( perl => './program' ) } ), 'interpreter-invalid', 'the version probe needs a pipe';
    }
    write_file( $path, "#!$^X\nprint STDERR qq{version diagnostic\\n};\nprint q{5.040};\n" );
    is ran( 0, $project, 'list', '--perl', './program' )->{stderr}, q{},
      'a successful probe keeps its diagnostics private';
    ok $selected->DOES('Test::Mutation::Value'), 'the selection refuses unknown constructor arguments';
    write_file( $path, "#!$^X\nprint q{5.040};\nexit 1;\n" );
    is refused( sub { $select->( perl => './program' ) } ), 'interpreter-invalid',
      'a failed version probe cannot supply a version';
    write_file( $path, "#!$^X\nprint q{5.009};\n" );
    is refused( sub { $select->( perl => './program' ) } ), 'interpreter-invalid', 'the shim requires Perl 5.10';
    {
        my $hidden = write_file( "$project/first/candidate",  "not executable\n" );
        my $usable = write_file( "$project/second/candidate", "#!$^X\nprint q{5.040};\n" );
        chmod 0600, $hidden or die $!;
        chmod 0700, $usable or die $!;
        local $ENV{PATH} = "$project/first:$project/second";
        is $select->( perl => 'candidate' )->perl, $usable, 'PATH skips a nonexecutable file before an interpreter';
        unlink $hidden or die $!;
        mkdir $hidden  or die $!;
        is $select->( perl => 'candidate' )->perl, $usable, 'PATH skips a searchable directory before an interpreter';
    }
    write_file( $path, "#!$^X\nprint q{6wrong};\n" );
    is refused( sub { $select->( perl => './program' ) } ), 'interpreter-invalid', 'the entire version must be numeric';
    write_file( $path, "#!$^X\nprint q{5.010};\n" );
    is $select->( perl => './program' )->perl, $path, 'the first supported interpreter is accepted';
    write_file( $path, "#!$^X\n" );
    is refused( sub { $select->( perl => './program' ) } ), 'interpreter-invalid',
      'a successful silent probe gives no version';
    write_file( $path, "#!/absent-interpreter-for-mutation\n" );
    is refused( sub { $select->( perl => './program' ) } ), 'interpreter-invalid',
      'an executable that cannot start gives no version';
    chmod 0600, $path or die $!;
    is refused( sub { $select->( perl => './program' ) } ), 'interpreter-invalid',
      'a non-executable file cannot run tests';
    return if !Capability::has( 'unprivileged', $> != 0, 'the root search permission needs an unprivileged account' );
    chmod 0600, $output or die $!;
    is refused( sub { $select->( root => $output ) } ), 'directory-closed', 'the library root needs search permission';
    chmod 0700, $output or die $!;
};

subtest 'output validation belongs to measurement and merging' => sub {
    my @invalid = ( '--format', 'terminal', '--format', 'json', '--report-dir', 'lib/Addition.pm/reports' );
    my $run     = World::observe( [ 'run', 'lib/Addition.pm', @invalid ], cwd => $project );
    is [ $run->@{qw(exit stdout)} ], [ 5, q{} ], 'a path-based run rejects its outputs before writing';
    my $listing = World::observe( [ 'list', 'lib/Addition.pm', @invalid ], cwd => $project );
    is $listing->{exit}, 0, 'a listing needs no writable report destination';
    my $all    = Test::Mutation::Select::resolve( config => config() )->mutants;
    my ($id)   = map { $_->id } grep { $_->mutator eq 'arithmetic' } @$all;
    my $prefix = substr $id, 0, 3;
    is refused( sub { Test::Mutation::Select::resolve( config => config( mutant => [$prefix] ) ) } ),
      'mutant-unknown', 'three digits are too short to select a mutant for measurement';
    is Test::Mutation::Select::resolve( config => config( mutant => [ substr $id, 0, 4 ] ) )->mutants->[0]->id,
      $id, 'a unique four-digit measurement prefix is sufficient';
};

subtest 'Git keeps both streams separate and retries interrupted reads and waits' => sub {
    my $git = write_file( "$project/tools/git", "#!$^X\n" . <<'PROGRAM' );
use strict;
use warnings;
my $command = $ARGV[3];
print STDERR "a warning that belongs to standard error\n";
if ($command eq 'rev-parse') { print "abcdef\n" }
if ($command eq 'diff') { print "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n" }
if ($command eq 'ls-files') { print 'lib/', ('nested/' x 60), "file-$_\0" for 1 .. 200 }
PROGRAM
    chmod 0700, $git or die $!;
    local $ENV{PATH} = "$project/tools";
    my $run = sub (%fault) {
        local $faults = { read_errors => [], wait_errors => [], finished => {}, %fault };
        local $SIG{ALRM} = sub { die "Git did not finish its fixture commands\n" };
        my $ready = \&IO::Select::can_read;
        my $count = \&IO::Select::count;
        my ( $reads, $checks ) = ( 0, 0 );
        no warnings 'redefine';
        local *IO::Select::count = sub (@args) {
            die "Git left the same pipe open without a read\n" if ++$checks > 1000;
            return $count->(@args);
        };
        local *IO::Select::can_read = sub (@args) {
            my @pipes    = $args[0]->handles;
            my $finished = $faults->{finished};
            die "Git left no open pipe to wait for\n" if !@pipes;
            die "Git left an unfinished pipe outside its wait set\n"
              if @pipes + keys(%$finished) != 2 || grep { $finished->{ fileno $_ } } @pipes;
            die "Git left its ready streams undrained\n" if ++$reads > 1000;
            return $ready->(@args);
        };

        # A writer that stays open after the child exits can prevent EOF.
        alarm 120;
        my $observed = eval { Test::Mutation::Git::changed( $project, 'HEAD' ) };
        my $error    = $@;
        alarm 0;
        die $error if !ref $error && $error =~ /Git (?:left|did not finish)/;
        is $faults->{reaped}, 3, 'Git reaps the revision, diff and listing processes after interruption' if $observed;
        return $observed || $error;
    };
    for my $fault ( {}, { read_errors => [ Errno::EINTR() ] }, { wait_errors => [ Errno::EINTR() ] },
        { stale_errno => 1 } )
    {
        my $observed = $run->(%$fault);
        is ref $observed, 'HASH', 'a successful read completes after a signal';
        next unless ref $observed eq 'HASH';
        is scalar( keys %$observed ), 201,          'a multi-buffer listing and the changed file, without diagnostics';
        is $observed->{a},            [ [ 1, 1 ] ], 'the diff comes from the output stream';
        my $prefix = 'lib/' . ( 'nested/' x 60 );
        ok exists $observed->{"${prefix}file-1"} && exists $observed->{"${prefix}file-200"},
          'both ends of the listing survived';
    }
    my $lost = $run->( wait_errors => [ Errno::ECHILD() ] );
    is ref $lost, 'Test::Mutation::Error', 'an unavailable child status cannot indicate successful Git output';
    is $lost->id, 'git-failed', 'the diagnostic identifies the failed Git command'
      if ref $lost eq 'Test::Mutation::Error';
    my $error = $run->( read_errors => [ Errno::EIO() ] );
    is ref $error, 'Test::Mutation::Error', 'a permanent read failure stops revision resolution';
    is $error->id, 'git-failed', 'the operating failure is reported by Git' if ref $error eq 'Test::Mutation::Error';
};

done_testing;
