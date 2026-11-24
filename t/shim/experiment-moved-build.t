use strict;
use warnings;
use Test::More;
use Config;
use ExtUtils::MakeMaker ();
use File::Copy          ();
use File::Find          ();
use File::Path          ();
use Time::HiRes         ();
use lib 't/shim/lib';
use ShimHarness qw(project write_file run_command need);

# Experiment E15: a built distribution that moves to another directory with the times of its files.
# The run builds a distribution in one copy and hands copies of that tree to its jobs, so make must find nothing to do there.

my $make       = $Config{make} || 'make';
my ($compiler) = split q{ }, $Config{cc};
my $root       = project();

# A make around this test hands its flags to every command below it, and a user may preset options of the build.
my %OWN_BUILD = map { $_ => undef } qw(MAKEFLAGS MFLAGS MAKELEVEL MAKEOVERRIDES PERL_MM_OPT PERL_MB_OPT);

sub in_tree {
    my ( $tree, @command ) = @_;
    my $run = run_command( root => $root, cwd => $tree, env => \%OWN_BUILD, command => \@command );
    $run->{output} = $run->{stdout} . $run->{stderr};
    return $run;
}

sub slurp {
    my ($path) = @_;
    open my $handle, '<', $path or return q{};
    local $/ = undef;
    my $content = <$handle>;
    close $handle or die "close $path: $!";
    return defined $content ? $content : q{};
}

sub mode_of {
    my ($path) = @_;
    return sprintf '%04o', ( stat $path )[2] & oct '7777';
}

sub modified {
    my ($path) = @_;
    return ( Time::HiRes::stat($path) )[9];
}

# The size and the time of every file of a tree.
sub snapshot {
    my ($tree) = @_;
    my %state;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if -d $File::Find::name;
                my @status = Time::HiRes::stat($File::Find::name);
                $state{ substr $File::Find::name, 1 + length $tree } = "$status[7] $status[9]";
            },
        },
        $tree
    );
    return \%state;
}

sub changed {
    my ( $before, $after ) = @_;
    my %names = map { $_ => 1 } keys %{$before}, keys %{$after};
    return [
        grep { ( defined $before->{$_} ? $before->{$_} : q{} ) ne ( defined $after->{$_} ? $after->{$_} : q{} ) }
        sort keys %names
    ];
}

# A copy of a tree, where the caller decides the times of each file.
sub copy_tree {
    my ( $from, $to, $stamp ) = @_;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $source = $File::Find::name;
                my $target = $to . substr $source, length $from;
                return File::Path::mkpath($target) if -d $source;
                File::Copy::copy( $source, $target ) or die "copy $source: $!";
                my @status = Time::HiRes::stat($source);
                chmod $status[2] & oct '7777', $target or die "chmod $target: $!";
                $stamp->( @status[ 8, 9 ], $target ) or die "time $target: $!";
            },
        },
        $from
    );
    return $to;
}

# A mutant arrives as a new file under the old name, with the mode of the file it replaces.
sub place {
    my ( $path, $text ) = @_;
    my $mode = ( stat $path )[2] & oct '7777';
    write_file( "$path.new", $text );
    chmod $mode, "$path.new" or die "chmod: $!";
    rename "$path.new", $path or die "rename: $!";
    return;
}

my %distribution = (
    pure => {
        'Makefile.PL' => "use ExtUtils::MakeMaker;\n"
          . "WriteMakefile( NAME => 'Moved::Pure', VERSION => '0.01', EXE_FILES => ['bin/moved'] );\n",
        'lib/Moved/Pure.pm' => "package Moved::Pure;\nour \$VERSION = '0.01';\nsub answer { return 41 }\n1;\n"
          . "__END__\n\n=head1 NAME\n\nMoved::Pure - a distribution without compiled code\n\n=cut\n",
        'bin/moved' => "#!/opt/unused/bin/perl\nuse Moved::Pure;\nprint Moved::Pure::answer(), \"\\n\";\n",
    },
    fast => {
        'Makefile.PL'       => "use ExtUtils::MakeMaker;\nWriteMakefile( NAME => 'Moved::Fast', VERSION => '0.01' );\n",
        'lib/Moved/Fast.pm' => "package Moved::Fast;\nour \$VERSION = '0.01';\nrequire XSLoader;\n"
          . "XSLoader::load( 'Moved::Fast', \$VERSION );\nsub twice { return 2 * answer() }\n1;\n",
        'Fast.xs' => qq{#include "EXTERN.h"\n#include "perl.h"\n#include "XSUB.h"\n\n}
          . "MODULE = Moved::Fast  PACKAGE = Moved::Fast\n\nint\nanswer()\n    CODE:\n        RETVAL = 21;\n"
          . "    OUTPUT:\n        RETVAL\n",
    },
);

# Sets the time of every file of a tree ten seconds back, to a whole second.
sub age {
    my ($tree) = @_;
    for my $path ( sort keys %{ snapshot($tree) } ) {
        my $earlier = int( modified("$tree/$path") ) - 10;
        utime $earlier, $earlier, "$tree/$path" or die "utime $path: $!";
    }
    return;
}

# Both distributions build before the first assertion, because a platform that cannot build them has no answer to give.
# The configuration looks ten seconds older than the build, which a distribution of some size brings about by itself.
# A build within the second of its configuration leaves a manual page that a later make writes again.
my %log;
for my $name ( sort keys %distribution ) {
    my $tree = "$root/$name/original";
    write_file( "$tree/$_", $distribution{$name}{$_} ) for sort keys %{ $distribution{$name} };
    my $configured = in_tree( $tree, $^X, 'Makefile.PL' );
    age($tree);
    my $built = $configured->{status} == 0 ? in_tree( $tree, $make ) : $configured;
    $log{$name} = "$configured->{output}$built->{output}" if $built->{status} != 0;
}
diag $log{$_} for sort keys %log;
need( 'toolchain', !%log, "the platform builds no distribution with $make and $compiler" );

my $object = "blib/arch/auto/Moved/Fast/Fast.$Config{dlext}";
my %module = ( pure => 'lib/Moved/Pure.pm', fast => 'lib/Moved/Fast.pm' );

# An interpreter that installs manual pages builds one for a module with documentation, and the pure module has some.
my $pages      = ( defined $Config{installman3dir} ? $Config{installman3dir} : q{} ) =~ /\A(?:none|\s*)\z/ ? 0 : 1;
my $page       = 'blib/man3/Moved::Pure.' . ( $Config{man3ext} || '3' );
my %built_page = ( pure => $pages ? [$page] : [], fast => [] );
is -e "$root/pure/original/$page" ? 1 : 0, $pages,
  'the build writes a manual page where the interpreter installs manual pages, and nowhere else';
ok -f "$root/pure/original/blib/lib/Moved/Pure.pm", 'the distribution without compiled code builds its copy under blib';
ok -f "$root/fast/original/$object",                'the distribution with compiled code builds its object';

# The copy of the driver sets fractional times, which the Time::HiRes of an older interpreter cannot do.
my $fine = Time::HiRes->can('utime');
my %copy = (
    'cp -Rp'        => sub { my ( $from, $to ) = @_; return in_tree( $root, 'cp', '-Rp', $from, $to )->{status} == 0 },
    'whole seconds' => sub {
        return copy_tree( @_, sub { return utime int $_[0], int $_[1], $_[2] } );
    },
);
$copy{'fractional seconds'} = sub {
    return copy_tree( @_, sub { return $fine->( $_[0], $_[1], $_[2] ) } );
  }
  if $fine;

# The answers follow the version of MakeMaker, and the interpreters at hand showed these versions:
# 6.6302, 6.66, 6.98, 7.0402, 7.1002, 7.24, 7.34, 7.44, 7.62, 7.64, 7.70, 7.76, and 7.78.
# A version outside the observed ranges may give either answer.
( my $maker = ExtUtils::MakeMaker->VERSION ) =~ tr/_//d;

sub is_by_version {
    my ( $got, $expected, $either, $name ) = @_;
    return is( $got, $expected, $name ) if defined $expected;
    return ok( scalar( grep { $got eq $_ } @{$either} ), "$name (MakeMaker $maker was not observed: @{$either})" )
      || diag "got: $got";
}

# The first make of MakeMaker 6.98 to 7.1002 leaves one step open for a compiled distribution.
# The second make writes the bootstrap file again, and from the third make on no file changes.
my @bootstrap =
    $maker >= 6.98 && $maker <= 7.1002                       ? ('Fast.bs')
  : ( $maker >= 6.6302 && $maker <= 6.66 ) || $maker >= 7.24 ? (q{})
  :                                                            ();
my %open_step = ( pure => q{}, fast => $bootstrap[0] );
for my $name ( sort keys %distribution ) {
    my $original = "$root/$name/original";

    # Each copy holds the tree as the first make left it.
    my %moved;
    for my $method ( sort keys %copy ) {
        ( $moved{$method} = "$root/$name/moved by $method" ) =~ tr/ /-/;
        ok $copy{$method}->( $original, $moved{$method} ), "a copy of the $name distribution by $method";
    }

    my $before = snapshot($original);
    is in_tree( $original, $make )->{status}, 0, "a second make succeeds in the tree of the $name distribution";
    my $open = changed( $before, snapshot($original) );
    is_by_version(
        "@{$open}", $open_step{$name},
        [ q{}, 'Fast.bs' ],
        "E15 $name: the files that a second make changes in the tree where the build ran"
    );
    $before = snapshot($original);
    is in_tree( $original, $make )->{status}, 0, "a third make succeeds in the tree of the $name distribution";
    is_deeply changed( $before, snapshot($original) ), [], "E15 $name: a third make changes no file there";

    for my $method ( sort keys %moved ) {
        $before = snapshot( $moved{$method} );
        my $run = in_tree( $moved{$method}, $make );
        is $run->{status}, 0, "E15 $name: make succeeds in a copy by $method" or diag $run->{output};
        is_deeply changed( $before, snapshot( $moved{$method} ) ), $open,
          "E15 $name: make in a copy by $method changes what the second make changes in the tree of the build, "
          . 'so the move reran neither Makefile.PL nor a build step';
    }
}

# A copy whose build looks ten seconds old, so a file that changes now is newer at any precision of a clock.
sub aged_copy {
    my ( $from, $to ) = @_;
    return copy_tree( $from, $to, sub { return utime int( $_[0] ) - 10, int( $_[1] ) - 10, $_[2] } );
}

# The control: make decides by the times alone, and a Makefile.PL that looks newer than the Makefile restarts the build.
my $stale = aged_copy( "$root/pure/original", "$root/pure/stale" );
my $later = 2 + int modified("$stale/Makefile");
utime $later, $later, "$stale/Makefile.PL" or die "utime: $!";
my $restarted = in_tree( $stale, $make );
isnt $restarted->{status}, 0, 'E15: make fails once where Makefile.PL is newer than the Makefile';
like $restarted->{output}, qr/^Makefile out-of-date with respect to Makefile[.]PL/m,
  'E15: because it reruns Makefile.PL';
ok !-e "$stale/blib/lib/Moved/Pure.pm", 'E15: and that rerun removes the build';
is in_tree( $stale, $make )->{status}, 0, 'E15: a second make builds the distribution again';
ok -f "$stale/blib/lib/Moved/Pure.pm", 'E15: with its copy under blib';

# After a placement, make carries the new text into the copy under blib and builds nothing else again.
my %placed = ( pure => 'sub answer { return 40 }', fast => 'sub twice { return 3 * answer() }' );
my %source = ( pure => 'sub answer { return 41 }', fast => 'sub twice { return 2 * answer() }' );
for my $name ( sort keys %distribution ) {
    my $path     = $module{$name};
    my $tree     = aged_copy( "$root/$name/original", "$root/$name/placed" );
    my $original = slurp("$tree/$path");
    my $old_time = int modified("$tree/$path");
    ( my $mutant = $original ) =~ s/\Q$source{$name}\E/$placed{$name}/ or die 'no place for the mutant';

    place( "$tree/$path", $mutant );
    my $before  = snapshot($tree);
    my $rebuilt = in_tree( $tree, $make );
    is $rebuilt->{status},        0,       "E15 $name: make succeeds after a placement" or diag $rebuilt->{output};
    is slurp("$tree/blib/$path"), $mutant, "E15 $name: and it carries the mutant into the copy under blib";
    is_deeply changed( $before, snapshot($tree) ), [ "blib/$path", @{ $built_page{$name} }, 'pm_to_blib' ],
      "E15 $name: it changes that copy, the stamp of the step, and the manual page of the module where one is built";

    # The original comes back with its old time, as a copy that keeps the times would write it.
    place( "$tree/$path", $original );
    utime $old_time, $old_time, "$tree/$path" or die "utime: $!";
    my $kept = in_tree( $tree, $make );
    is $kept->{status}, 0, "E15 $name: make succeeds after the original came back";
    is slurp("$tree/blib/$path"), $mutant,
      "E15 $name: a file that came back with its old time leaves the mutant in the copy under blib";
}

# The build compares a manual page with the Makefile, and it writes a page of the same age once more.
# A copy that cuts the times to whole seconds can leave a page of a quick build in that state.
my $same_second = aged_copy( "$root/pure/original", "$root/pure/same-second" );
if ($pages) {
    my $configured = int modified("$same_second/Makefile");
    utime $configured, $configured, "$same_second/$page" or die "utime: $!";
}
my $before_pages = snapshot($same_second);
is in_tree( $same_second, $make )->{status}, 0, 'make succeeds where a manual page is as old as the Makefile';
is_deeply changed( $before_pages, snapshot($same_second) ), $built_page{pure},
  'E15: make writes a manual page again that is as old as the Makefile, where the interpreter builds manual pages';

# E14 in a real build: the copy under blib has mode 0444, and a rename replaces it.
my $built_copy = "$root/pure/original/blib/lib/Moved/Pure.pm";
is mode_of($built_copy), '0444', 'E14: the build gives the copy under blib the mode 0444';
place( $built_copy, "package Moved::Pure;\nsub answer { return 39 }\n1;\n" );
is mode_of($built_copy), '0444', 'E14: a placement by rename replaces that copy and keeps its mode';
is in_tree( "$root/pure/original", $^X, '-Iblib/lib', 'bin/moved' )->{stdout}, "39\n",
  'E14: and a program loads the placed text';

# The script under blib is a copy with another first line, which the build writes for the interpreter that ran it.
my @script = split /^/m, slurp("$root/pure/original/bin/moved");
my @copied = split /^/m, slurp("$root/pure/original/blib/script/moved");
isnt $copied[0], $script[0], 'E15: the build rewrites the first line of a script for its copy under blib';
is_deeply [ @copied[ -2, -1 ] ], [ @script[ -2, -1 ] ], 'E15: and it keeps the lines of the program';

# MakeMaker 6.6302 to 6.98 adds three lines that start the interpreter from a shell, and 7.0402 and later add none.
my $added = $maker >= 6.6302 && $maker <= 6.98 ? 3 : $maker >= 7.0402 ? 0 : undef;
is_by_version(
    scalar(@copied) - scalar(@script),
    $added,
    [ 0, 3 ],
    'E15: the lines that the copy of a script holds more than the script, which shift its line numbers'
) or diag join q{}, @copied;

# E11 in a real build: the object of the copy under blib joins the list of the loaded objects.
write_file( "$root/fast/loaded.pl",
    "use Moved::Fast;\nprint Moved::Fast::twice(), q{ }, join( q{,}, grep { /Fast/ } \@DynaLoader::dl_shared_objects ), \"\\n\";\n"
);
for my $name (qw(original moved-by-cp--Rp)) {
    my $tree = "$root/fast/$name";
    is in_tree( $tree, $^X, "-I$tree/blib/lib", "-I$tree/blib/arch", "$root/fast/loaded.pl" )->{stdout},
      "42 $tree/$object\n",
      "E11: a program loads the object of the $name tree, and the list names it under its library directory";
}

done_testing;
