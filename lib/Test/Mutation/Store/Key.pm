package Test::Mutation::Store::Key;
use v5.36;
use Config          qw(%Config);
use Cwd             ();
use Digest::SHA     ();
use Encode          ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef Bool HashRef Maybe Optional Slurpy Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;

our $VERSION = '0.001';

my %last_file;
my %volatile = map { $_ => 1 } qw(
  PWD OLDPWD SHLVL _ TMPDIR HARNESS_ACTIVE HARNESS_VERSION
  GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_RUN_ATTEMPT GITHUB_STEP_SUMMARY GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STATE
  RUNNER_TEMP RUNNER_TRACKING_ID CI_JOB_ID CI_PIPELINE_ID
  TEST_MUTATION_ROOT TEST_MUTATION_GENERATION TEST_MUTATION_SPEC TEST_MUTATION_RECORD
);

signature_for digest => ( positional => [ Slurpy [ ArrayRef [Str] ] ], returns => Str );

sub digest ($parts) {
    my $sha = Digest::SHA->new(256);
    for my $part (@$parts) {
        my $bytes = utf8::is_utf8($part) ? Encode::encode_utf8($part) : $part;
        $sha->add( length($bytes) . q{:} . $bytes );
    }
    return $sha->hexdigest;
}

signature_for environment => ( positional => [ HashRef [ Maybe [Str] ], Optional [ Maybe [Str] ] ], returns => Str );

sub environment ( $env, $project = undef ) {
    my @names = sort grep { defined $env->{$_} && !$volatile{$_} && $_ !~ /\ATEST_MUTATION_(?:SPEC|RECORD)_G[0-9]+\z/x }
      keys %$env;
    my %values = %$env;
    if ( defined $project ) {
        my $separator = $Config{path_sep};
        for my $name ( grep { defined $values{$_} } qw(PATH PERL5LIB PERLLIB) ) {
            $values{$name} = digest(
                map { index( "$_/", "$project/" ) == 0 ? ( 'project', substr( $_, length $project ) ) : ( 'path', $_ ) }
                  split /\Q$separator\E/,
                $values{$name},
                -1
            );
        }
    }
    return digest( map { ( $_, $values{$_} ) } @names );
}

signature_for file => ( positional => [Str], returns => Str );

sub file ($path) {
    my @stat     = Time::HiRes::stat($path);
    my $identity = @stat ? join( q{/}, @stat[ 0, 1, 2, 7, 9, 10 ] ) : undef;
    my $previous = $last_file{$path};
    return $previous->[1]
      if $previous && defined $identity && $previous->[0] eq $identity && $stat[10] < Time::HiRes::time() - 2;
    open my $input, '<:raw', $path
      or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    my $value = Digest::SHA->new(256)->addfile($input)->hexdigest;
    close $input or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    $last_file{$path} = [ $identity, $value ] if defined $identity;
    return $value;
}

signature_for tree => ( positional => [ Str, ArrayRef [Str], Optional [Bool] ], returns => Str );

sub tree ( $root, $skip, $omit_reports = 0 ) {
    return digest('absent') unless -d $root;
    my %skip = map { $_ => 1 } @$skip;
    require Test::Mutation::Report::Publication if $omit_reports;
    my @files;
    _walk( $root, q{}, \%skip, {}, \@files, $omit_reports );
    return digest(@files);
}

sub _walk ( $root, $relative, $skip, $parents, $files, $omit_reports ) {
    my $directory = length $relative ? "$root/$relative" : $root;
    my @inode     = ( stat $directory )[ 0, 1 ];
    my $identity  = join q{/}, @inode;
    return if $parents->{$identity};
    local $parents->{$identity} = 1;
    opendir my $dir, $directory
      or Test::Mutation::Error::raise( 'directory-unopenable', path => $directory, reason => "$!" );
    my @names = sort grep { $_ ne q{.} && $_ ne q{..} } readdir $dir;
    closedir $dir or Test::Mutation::Error::raise( 'file-unclosable', path => $directory, reason => "$!" );

    my $start     = @$files;
    my $reported  = 0;
    my $published = $omit_reports ? Test::Mutation::Report::Publication::outputs( $directory, $relative ) : {};
    for my $name (@names) {
        my $path = length $relative ? "$relative/$name" : $name;
        next if $skip->{$path};
        my $absolute = "$root/$path";
        my ( $output, $digest ) = _published( $published, $name, $absolute );
        if ($output) {
            $reported = 1;
            next;
        }
        my $offset = @$files;
        push @$files, 'link', $path, readlink $absolute if -l $absolute;
        if ( -d $absolute ) {
            push @$files, 'directory', $path;
            if ( _walk( $root, $path, $skip, $parents, $files, $omit_reports ) ) {
                splice @$files, $offset;
                $reported = 1;
            }
        }
        elsif ( -f $absolute ) {
            push @$files, 'file', $path, ( ( stat $absolute )[2] & oct '111' ), $digest || file($absolute);
        }
    }
    return $reported && @$files == $start;
}

sub _published ( $published, $name, $path ) {
    return ( 0, undef ) if !exists $published->{$name} || -l $path || !-f $path;
    my $expected = $published->{$name};
    return ( 1, undef ) unless defined $expected;
    my $digest = file($path);
    return ( $digest eq $expected, $digest );
}

signature_for interpreter => ( positional => [Str], returns => Str );

sub interpreter ($program) {
    my ( $path, $actual, $configuration ) = _interpreter($program);
    return digest( $path, file($path), $actual, file($actual), $configuration );
}

signature_for interpreter_build => ( positional => [Str], returns => Str );

sub interpreter_build ($program) {
    my ( $path, $actual, $configuration ) = _interpreter($program);
    return digest( file($path), file($actual), $configuration );
}

sub _interpreter ($program) {
    my $path = Cwd::abs_path($program);
    my ( $actual, $configuration );
    if ( $path eq Cwd::abs_path($^X) ) {
        ( $actual, $configuration ) = ( $path, Config::config_sh() );
    }
    else {
        delete local $ENV{PERL5OPT};
        open my $child, q{-|}, $path, '-MConfig', '-e', 'print $^X, "\0", Config::config_sh()'
          or Test::Mutation::Error::raise( 'interpreter-invalid', program => $program );
        my $data = do { local $/ = undef; readline $child };
        close $child or Test::Mutation::Error::raise( 'interpreter-invalid', program => $program );
        ( $actual, $configuration ) = split /\0/, $data, 2 if defined $data;
        Test::Mutation::Error::raise( 'interpreter-invalid', program => $program )
          unless length($configuration) && -f $actual;
    }
    return ( $path, $actual, $configuration );
}

1;

__END__

=head1 NAME

Test::Mutation::Store::Key - fingerprint the inputs to a mutation measurement

=head1 FUNCTIONS

=head2 digest

Hashes each input with its byte length so different input boundaries stay distinct.

=head2 environment

Hashes the environment that a test inherits after removing driver assignments and volatile run identifiers.
With a project root, library and executable search paths within the project compare by their relative names.

=head2 file

Hashes the bytes of a regular file.

=head2 tree

Hashes relative names, executable bits, symlinks and contents below a directory.
The caller can exclude inputs that have separate keys.
An optional true third argument omits generated mutation reports and directories containing only those reports.

=head2 interpreter

Hashes both the selected executable and the Perl binary and configuration it runs.

=head2 interpreter_build

Identifies the selected executable, the Perl binary, and the compiled configuration across checkout locations.

=cut
