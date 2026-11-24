package Discovery::Zoo;
use v5.36;
use IO::Socket::INET ();
use Discovery::Known;

# The hostile test zoo: the cells of one known-answer project under one behavior for each member.
# A member that depends on a mutant misbehaves when a cell returns a wrong value alone, so its unmodified run passes.

my $HOLD_SECONDS = 0.5;
my $LIFE_SECONDS = 30;
my $FIXED_TIME   = 1_700_000_000;

# The function value of a test calls a cell in the process of the test or asks a child process for the answer.
my $BY_PACKAGE = <<'PERL';
sub value { my ( $cell, @arguments ) = @_; return scalar <<package>>->can($cell)->(@arguments) }
PERL

my $BY_CHILD = <<'PERL';
sub value {
    my ( $cell, @arguments ) = @_;
    open my $pipe, '-|', <<command>>, $cell, @arguments or die "cannot start the child: $!";
    my $answer = readline $pipe;
    close $pipe;
    return defined $answer && $answer =~ /\Avalue (.*)\n\z/ ? $1 : undef;
}
PERL

my $BY_FORK = <<'PERL';
sub value {
    my ( $cell, @arguments ) = @_;
    pipe my $read, my $write or die "pipe: $!";
    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        close $read;
        require <<package>>;
        my $value = <<package>>->can($cell)->(@arguments);
        print {$write} defined $value ? "value $value\n" : "undefined\n";
        close $write;
        exit 0;
    }
    close $write;
    my $answer = readline $read;
    close $read;
    waitpid $pid, 0;
    return defined $answer && $answer =~ /\Avalue (.*)\n\z/ ? $1 : undef;
}
PERL

my $ANSWER =
    q[my ( $cell, @arguments ) = @ARGV; my $value = <<package>>->can($cell)->(@arguments); ]
  . q[print defined $value ? "value $value\n" : "undefined\n";];
my $ONE_LINER = q[$^X, '-Ilib', '-M<<package>>', '-e', ] . Discovery::Known::quoted($ANSWER);

my $EVALUATE = <<'PERL';
{
    open my $source, '<', '<<target>>' or die "read: $!";
    my $text = do { local $/; <$source> };
    close $source;
    eval $text or die "cannot evaluate the text: $@";
}
PERL

my $READ_DATA = <<'PERL';
{
    my $line = readline *<<package>>::DATA;
    die "the data handle gives no payload\n" if !defined $line || $line ne "payload\n";
}
PERL

my $WRITE_FILE = <<'PERL';
{
    mkdir 'out';
    open my $out, '>', 'out/written.txt' or die "write: $!";
    print {$out} "written\n";
    close $out;
}
PERL

my $SEAL = <<'PERL';
if ( !-d 'sealed' ) {
    mkdir 'sealed' or die "mkdir: $!";
    open my $out, '>', 'sealed/inside.txt' or die "write: $!";
    close $out;
    chmod 0, 'sealed' or die "chmod: $!";
}
PERL

my $READ_TABLE = <<'PERL';
{
    open my $in, '<', 'data/table.txt' or die "read: $!";
    my $text = <$in>;
    close $in;
    die "the table changed\n" if $text ne "AAAA\n";
}
PERL

# The rewrite keeps the size and restores the time, as a tool that preserves timestamps does.
my $REWRITE_TABLE = <<'PERL';
{
    my @time = ( stat 'data/table.txt' )[ 8, 9 ];
    open my $out, '>', 'data/table.txt' or die "write: $!";
    print {$out} "BBBB\n";
    close $out;
    utime @time, 'data/table.txt';
}
print "not ok $number - $cell\n";
PERL

my $TAKE_PATH = <<'PERL';
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
sysopen my $fixed, '<<fixed>>', O_CREAT | O_EXCL | O_WRONLY or die "the fixed path is taken: $!\n";
close $fixed;
my $holds = 1;
END { unlink '<<fixed>>' if $holds }
select undef, undef, undef, <<hold>>;
PERL

my $TAKE_PORT = <<'PERL';
use IO::Socket::INET ();
my $listener = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => <<port>>, Proto => 'tcp' )
  or die "the fixed port is taken: $!\n";
select undef, undef, undef, <<hold>>;
PERL

my $TAKE_LOCK = <<'PERL';
use Fcntl qw(LOCK_EX LOCK_NB);
open my $lock, '>>', 'data/lock' or die "open: $!";
flock $lock, LOCK_EX | LOCK_NB or die "the lock is taken: $!\n";
select undef, undef, undef, 0.2;
PERL

my $PLAIN = "use <<package>>;\n" . $BY_PACKAGE;

# A process that a test leaves writes its own number into the registry, and it ends on its own after a few seconds.
my $REGISTER = <<'PERL';
use POSIX ();
sub register {
    my ($label) = @_;
    open my $file, '>', '<<registry>>/' . $$ . '.new' or return;
    print {$file} "$label\n";
    close $file;
    rename '<<registry>>/' . $$ . '.new', '<<registry>>/' . $$;
    return;
}
PERL

my $HOLD_OUTPUT = <<'PERL';
{
    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        register('the child of <<test>> that holds standard output');
        select undef, undef, undef, 1;
        POSIX::_exit(0);
    }
}
PERL

my $LEAVE_GROUP = <<'PERL';
{
    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        setpgrp 0, 0;
        open STDIN,  '<', '/dev/null';
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        register('the child of <<test>> that left the process group');
        select undef, undef, undef, <<life>>;
        POSIX::_exit(0);
    }
}
PERL

my $DAEMON = <<'PERL';
{
    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        POSIX::setsid();
        my $inner = fork;
        POSIX::_exit(0) if !defined $inner || $inner;
        open STDIN,  '<', '/dev/null';
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        register('the daemon of <<test>>');
        select undef, undef, undef, <<life>>;
        POSIX::_exit(0);
    }
    waitpid $pid, 0;
}
PERL

my $WRONG_IN_BEGIN = <<'PERL';
BEGIN {
    for my $row (
<<rows>>      )
    {
        my $got = value( $row->[0], @{ $row->[1] } );
        die "a cell is wrong while the test compiles\n" if !defined $got || $got ne $row->[2];
    }
}
PERL

my $WRONG_IN_END  = qq[END { die "a cell was wrong\\n" if \$main::wrong }\n];
my $ANOTHER       = q[exec $^X, '-e', 'print "not ok 99 - another program\n"; exit 1' or die "exec: $!";];
my $FLOOD         = q[print '# ' . ( 'x' x 1022 ) . "\n" for 1 .. 100_000; line("not ok $number - $cell");];
my $EMPTY_INPUT   = qq[{ my \$line = <STDIN>; die "standard input holds a line\\n" if defined \$line; }\n];
my $IN_TAINT_MODE = qq[die "the test runs without taint mode\\n" if !\${^TAINT};\n];

# A process may inherit a signal as ignored, so the test takes the default action back before it signals itself.
sub _signal ($name) {
    my $wrong = "\$SIG{$name} = 'DEFAULT'; kill '$name', \$\$; sleep 5;";
    return [ process => 'kill-' . lc $name, { load => $PLAIN, wrong => $wrong } ];
}

sub _taint ( $name, $first ) {
    return [ taint => $name, { load => $PLAIN . $IN_TAINT_MODE, first => $first } ];
}

sub _path ( $name, $directory ) {
    return [ path => $name, { load => $PLAIN, directory => $directory, alone => 1 } ];
}

# A member names where its cells live and how its test loads them.
# `files` lists more files of the project, and `wrong` is the code of the test for a wrong value.
# `alone` gives the member a project of its own, with the `settings` of its run and the `directory` of the project.
# `turns` maps a status of the truth to the status that the behavior of the member makes of it.
my @MEMBERS = (
    [ process => 'exit-without-plan', { load => $PLAIN, plan => 'last', wrong => 'exit 0;' } ],
    [ process => 'die-in-begin',      { load => $PLAIN . $WRONG_IN_BEGIN } ],
    [
        process => 'die-in-end',
        { load => $PLAIN . $WRONG_IN_END, wrong => q[$main::wrong = 1; line("ok $number - $cell");] }
    ],
    ( map { _signal($_) } qw(HUP INT TERM KILL SEGV PIPE) ),
    [ process => 'posix-exit',         { load => "use POSIX ();\n" . $PLAIN, wrong => 'POSIX::_exit(0);' } ],
    [ process => 'exec',               { load => $PLAIN,                     wrong => $ANOTHER } ],
    [ process => 'child-holds-stdout', { load => $PLAIN . $REGISTER . $HOLD_OUTPUT } ],
    [ process => 'child-leaves-group', { load => $PLAIN . $REGISTER . $LEAVE_GROUP } ],
    [ process => 'daemonize',          { load => $PLAIN . $REGISTER . $DAEMON } ],
    [
        process => 'close-stdout',
        {
            load     => $PLAIN,
            end      => "close STDOUT;\nselect undef, undef, undef, 1;\n",
            settings => { jobs => 1 },
            idle     => 1,
            alone    => 1
        }
    ],
    [
        process => 'redirect-stdout',
        { load => $PLAIN, end => "open STDOUT, '>', '/dev/null';\nselect undef, undef, undef, 0.1;\n" }
    ],
    [
        process => 'endless-loop',
        {
            load     => $PLAIN,
            wrong    => '1 while 1;',
            turns    => { Killed => 'Timeout' },
            settings => { shard  => '1/4', timeout_floor => 2 },
            alone    => 1
        }
    ],

    [ io => 'big-output',       { load => $PLAIN, wrong   => $FLOOD, settings => { shard => '1/8' }, alone => 1 } ],
    [ io => 'no-final-newline', { load => $PLAIN, newline => 'before' } ],
    [ io => 'read-stdin',       { load => $PLAIN . $EMPTY_INPUT } ],

    _taint( 'taint-T',         '#!perl -T' ),
    _taint( 'taint-bundle-wT', '#!perl -wT' ),
    _taint( 'taint-bundle-Tw', '#!perl -Tw' ),
    _taint( 'taint-lower',     '#!perl -t' ),
    _taint( 'taint-include',   '#!perl -It/lib' ),
    _taint( 'taint-separate',  '#!perl -w -T' ),
    _taint( 'taint-space',     '#! perl -T' ),
    _taint( 'taint-tab',       "#!perl\t-T" ),
    [
        taint => 'taint-explicit',
        { load => $PLAIN . $IN_TAINT_MODE, switches => [ '-Ilib', '-T' ], prove => ['-T'], alone => 1 }
    ],

    _path( 'path-space',     'pro ject' ),
    _path( 'path-colon',     'pro:ject' ),
    _path( 'path-quote',     q{pro'ject"} ),
    _path( 'path-glob',      'pro[j]e*ct?' ),
    _path( 'path-non-ascii', "pro\xc3\xa9ject" ),
    _path( 'path-hash',      'pro#ject' ),

    [ loading => 'use',       { load => "use <<package>>;\n" . $BY_PACKAGE } ],
    [ loading => 'require',   { load => "require <<package>>;\n" . $BY_PACKAGE } ],
    [ loading => 'use-lib',   { load => "use lib 'lib';\nuse <<package>>;\n" . $BY_PACKAGE } ],
    [ loading => 'local-inc', { load => "{ local \@INC = ( 'lib', \@INC ); require <<package>>; }\n" . $BY_PACKAGE } ],
    [ loading => 'fresh-inc', { load => "BEGIN { \@INC = ('lib') }\nuse <<package>>;\n" . $BY_PACKAGE } ],
    [
        loading => 'absolute-copy',
        { load => "use Cwd ();\nrequire( Cwd::getcwd() . '/<<target>>' );\n" . $BY_PACKAGE }
    ],
    [ loading => 'absolute-original', { load => "require '<<root>>/<<target>>';\n" . $BY_PACKAGE } ],
    [ loading => 'do-file',   { load => "do './<<target>>' or die \"cannot load: \$@ \$!\";\n" . $BY_PACKAGE } ],
    [ loading => 'eval-text', { load => $EVALUATE . $BY_PACKAGE } ],
    [
        loading => 'data-handle',
        { load => "use <<package>>;\n" . $READ_DATA . $BY_PACKAGE, after => "__DATA__\npayload\n" }
    ],
    [ loading => 'forked-child',  { load => $BY_FORK } ],
    [ loading => 'system-perl',   { load => $BY_CHILD, command => q[$^X, '<<target>>'], script => '#!/usr/bin/perl' } ],
    [ loading => 'direct-script', { load => $BY_CHILD, command => q['./<<target>>'],    script => '#!<<perl>>' } ],
    [
        loading => 'perl-x',
        { load => $BY_CHILD, command => q[$^X, '-x', '<<target>>'], script => "This line is no Perl.\n#!perl" }
    ],
    [ loading => 'cleared-perl5opt', { load => "delete \$ENV{PERL5OPT};\n" . $BY_CHILD, command => $ONE_LINER } ],
    [ loading => 'cleared-perl5lib', { load => "delete \$ENV{PERL5LIB};\n" . $BY_CHILD, command => $ONE_LINER } ],
    [ loading => 'cleared-env',      { load => "%ENV = ();\n" . $BY_CHILD,              command => $ONE_LINER } ],

    [ files => 'chdir', { load => "BEGIN { chdir 't' or die \"chdir: \$!\" }\nuse <<package>>;\n" . $BY_PACKAGE } ],
    [ files => 'write-file', { load => "use <<package>>;\n" . $WRITE_FILE . $BY_PACKAGE } ],
    [
        files => 'remove-file',
        {
            load  => "use <<package>>;\nunlink 'data/removable.txt';\n" . $BY_PACKAGE,
            files => { 'data/removable.txt' => "removable\n" }
        }
    ],
    [
        files => 'chmod-file',
        {
            load  => "use <<package>>;\nchmod 0400, 'data/mode.txt' or die \"chmod: \$!\";\n" . $BY_PACKAGE,
            files => { 'data/mode.txt' => "mode\n" }
        }
    ],
    [ files => 'mode-0-directory', { load => "use <<package>>;\n" . $SEAL . $BY_PACKAGE } ],
    [
        files => 'mkdir-out',
        { load => "use <<package>>;\nmkdir 'out' or die \"mkdir: \$!\";\n" . $BY_PACKAGE, alone => 1 }
    ],
    [
        files => 'same-size-rewrite',
        {
            load  => "use <<package>>;\n" . $READ_TABLE . $BY_PACKAGE,
            wrong => $REWRITE_TABLE,
            files => { 'data/table.txt' => "AAAA\n" },
            jobs  => 1,
            alone => 1
        }
    ],
    [ files => 'fixed-tmp-path', { load => "use <<package>>;\n" . $TAKE_PATH . $BY_PACKAGE, alone => 1 } ],
    [ files => 'fixed-port',     { load => "use <<package>>;\n" . $TAKE_PORT . $BY_PACKAGE, alone => 1 } ],
    [
        files => 'lock-file',
        { load => "use <<package>>;\n" . $TAKE_LOCK . $BY_PACKAGE, files => { 'data/lock' => q{} } }
    ],
);

sub names ($axis) {
    return map { $_->[1] } grep { $_->[0] eq $axis } @MEMBERS;
}

sub _member ($name) {
    my ($member) = grep { $_->[1] eq $name } @MEMBERS;
    return $member || die "the zoo has no member named $name\n";
}

# True for a member whose behavior reaches other tests or the whole run, and that therefore gets a project of its own.
sub alone ($name) {
    return _member($name)->[2]{alone} ? 1 : 0;
}

# The name of the directory of the project, for a member that needs a name of its own.
sub directory ($name) {
    my $directory = _member($name)->[2]{directory};
    return defined $directory ? $directory : 'project';
}

sub new ( $class, %arg ) {
    my @tests = $arg{known}->tests;
    die "the cells of the zoo have one test\n" if @tests != 1;
    return bless { known => $arg{known}, test => $tests[0] }, $class;
}

sub known ($self) {
    return $self->{known};
}

# The source patterns of a project of the zoo, which holds cells in modules and in scripts.
sub sources () {
    return [ 'lib/**/*.pm', 'script/*' ];
}

sub _filled ( $template, $value ) {
    return $template =~ s{<<(\w+)>>}{defined $value->{$1} ? $value->{$1} : die "the template names no $1\n"}ger;
}

# The kernel gives a port that no process holds, and the tests of one project then compete for it.
sub _free_port () {
    my $socket = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' )
      or die "no free port: $!";
    my $port = $socket->sockport;
    close $socket or die "close: $!";
    return $port;
}

# The words that the templates of a member name, each with its value in one project.
sub _values ( $self, $project, $name, $spec ) {
    my ($token) = $project->scratch =~ m{([^/]+)\z};
    my $package = 'Zoo::' . join q{}, map { ucfirst } split /-/, $name;
    my %value   = (
        package  => $package,
        target   => defined $spec->{script} ? "script/$name.pl" : 'lib/' . $package =~ s{::}{/}gr . '.pm',
        test     => "t/$name.t",
        root     => $project->root,
        registry => $project->registry,
        perl     => $^X,
        fixed    => "/tmp/$token-$name",
        hold     => $HOLD_SECONDS,
        life     => $LIFE_SECONDS,
        port     => $name eq 'fixed-port' ? _free_port() : 0,
        rows     => $self->{known}->rows_text( $self->{test} ),
    );
    $value{command} = _filled( $spec->{command}, \%value ) if defined $spec->{command};
    return \%value;
}

# Writes the cells of a member as a module or as a script, and returns the lines that stand above the script.
sub _write_cells ( $self, $project, $spec, $value ) {
    if ( defined $spec->{script} ) {
        my $first = _filled( $spec->{script}, $value );
        $project->write( $value->{target}, $self->{known}->script($first), mode => oct '755' );
        return $first =~ tr/\n//;
    }
    my $after = defined $spec->{after} ? $spec->{after} : q{};
    $project->write( $value->{target}, $self->{known}->module( $value->{package} ) . $after );
    return 0;
}

# The settings of the run of a member: its own ones, and a configuration file for switches that no flag carries.
sub _settings ( $project, $name, $spec ) {
    my %settings = %{ $spec->{settings} || {} };
    $settings{jobs} = $spec->{jobs} if defined $spec->{jobs};
    return \%settings if !$spec->{switches};
    my $file = $project->scratch . "/$name.toml";
    open my $handle, '>', $file or die "write $file: $!";
    printf {$handle} "[test]\nswitches = [%s]\n", join ', ', map { qq{"$_"} } $spec->{switches}->@*
      or die "write $file: $!";
    close $handle or die "close $file: $!";
    return { %settings, configuration => $file };
}

# Writes the files of the named members and returns, for each one, its test, the file of its cells, and its settings.
sub build ( $self, $project, @names ) {
    my ( %built, %taken );
    for my $name (@names) {
        my $spec  = _member($name)->[2];
        my $value = $self->_values( $project, $name, $spec );
        die "two members of the zoo hold their cells in $value->{target}\n" if $taken{ lc $value->{target} }++;
        my $shift = $self->_write_cells( $project, $spec, $value );
        $project->write(
            $value->{test},
            $self->{known}->test_text(
                $self->{test},
                load => _filled( $spec->{load}, $value ),
                map { defined $spec->{$_} ? ( $_ => $spec->{$_} ) : () } qw(wrong first plan end newline),
            )
        );
        $project->write( $_, $spec->{files}{$_}, time => $FIXED_TIME ) for sort keys %{ $spec->{files} || {} };
        $built{$name} = {
            name     => $name,
            test     => $value->{test},
            target   => $value->{target},
            shift    => $shift,
            settings => _settings( $project, $name, $spec ),
            turns    => $spec->{turns} || {},
            idle     => $spec->{idle} ? 1 : 0,
            prove    => $spec->{prove} || [],
        };
    }
    return \%built;
}

1;
