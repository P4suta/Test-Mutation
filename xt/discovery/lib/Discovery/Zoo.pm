package Discovery::Zoo;
use v5.36;
use IO::Socket::INET ();
use Discovery::Known;

# The hostile test zoo: the cells of one known-answer project under one behavior for each member.
# A member that depends on a mutant misbehaves when a cell returns a wrong value alone, so its unmodified run passes.

my $HOLD_SECONDS = 0.5;
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

# A member names where its cells live and how its test loads them.
# `files` lists more files of the project, and `wrong` is the code of the test for a wrong value.
my @MEMBERS = (
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
    [ files => 'mkdir-out',        { load => "use <<package>>;\nmkdir 'out' or die \"mkdir: \$!\";\n" . $BY_PACKAGE } ],
    [
        files => 'same-size-rewrite',
        {
            load  => "use <<package>>;\n" . $READ_TABLE . $BY_PACKAGE,
            wrong => $REWRITE_TABLE,
            files => { 'data/table.txt' => "AAAA\n" },
            jobs  => 1
        }
    ],
    [ files => 'fixed-tmp-path', { load => "use <<package>>;\n" . $TAKE_PATH . $BY_PACKAGE } ],
    [ files => 'fixed-port',     { load => "use <<package>>;\n" . $TAKE_PORT . $BY_PACKAGE } ],
    [
        files => 'lock-file',
        { load => "use <<package>>;\n" . $TAKE_LOCK . $BY_PACKAGE, files => { 'data/lock' => q{} } }
    ],
);

sub names ($axis) {
    return map { $_->[1] } grep { $_->[0] eq $axis } @MEMBERS;
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

# Writes the files of the named members and returns, for each one, its test, the file of its cells, and its settings.
sub build ( $self, $project, @names ) {
    my %spec = map { $_->[1] => $_->[2] } @MEMBERS;
    my ($token) = $project->scratch =~ m{([^/]+)\z};
    my %built;
    for my $name (@names) {
        my $spec    = $spec{$name} or die "the zoo has no member named $name\n";
        my $package = 'Zoo::' . join q{}, map { ucfirst } split /-/, $name;
        my $target  = defined $spec->{script} ? "script/$name.pl" : 'lib/' . $package =~ s{::}{/}gr . '.pm';
        my %value   = (
            package => $package,
            target  => $target,
            root    => $project->root,
            perl    => $^X,
            fixed   => "/tmp/$token-$name",
            hold    => $HOLD_SECONDS,
            port    => $name eq 'fixed-port' ? _free_port() : 0,
        );
        $value{command} = _filled( $spec->{command}, \%value ) if defined $spec->{command};

        if ( defined $spec->{script} ) {
            my $first = _filled( $spec->{script}, \%value );
            $project->write( $target, $self->{known}->script($first), mode => oct '755' );
            $built{$name}{shift} = $first =~ tr/\n//;
        }
        else {
            my $after = defined $spec->{after} ? $spec->{after} : q{};
            $project->write( $target, $self->{known}->module($package) . $after );
            $built{$name}{shift} = 0;
        }
        my $test = "t/$name.t";
        $project->write(
            $test,
            $self->{known}->test_text(
                $self->{test},
                load => _filled( $spec->{load}, \%value ),
                ( defined $spec->{wrong} ? ( wrong => $spec->{wrong} ) : () ),
            )
        );
        $project->write( $_, $spec->{files}{$_}, time => $FIXED_TIME ) for sort keys %{ $spec->{files} || {} };
        $built{$name} = { $built{$name}->%*, name => $name, test => $test, target => $target, jobs => $spec->{jobs} };
    }
    return \%built;
}

1;
