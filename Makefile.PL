use 5.036;
use strict;
use warnings;
use ExtUtils::MakeMaker;

# cpanfile is the one place that declares requirements, and these two subroutines read its phases.
my %requirements = ( runtime => {}, test => {} );
my $phase        = 'runtime';

sub requires {
    my ( $module, $version ) = @_;
    $requirements{$phase}{$module} = defined $version ? $version : 0 if $requirements{$phase};
    return;
}

sub on {
    my ( $name, $declare ) = @_;
    my $outer = $phase;
    $phase = $name;
    $declare->();
    $phase = $outer;
    return;
}

do './cpanfile';
die "cannot read cpanfile: $@\n"                 if $@;
die "cpanfile declares no runtime requirement\n" if !%{ $requirements{runtime} };

# The driver signals process groups and reads the process table, which Windows offers in no comparable form.
die "OS unsupported\n" if $^O eq 'MSWin32';

# An installation runs the quick tests, and EXTENDED_TESTING adds the end-to-end tests, which start many processes.
my @tests = ( 't/unit/*.t', 't/shim/*.t', 't/assumptions/*.t', $ENV{EXTENDED_TESTING} ? 't/e2e/*.t' : () );
my $home  = 'https://github.com/P4suta/permutl';

WriteMakefile(
    NAME             => 'Permutl',
    ABSTRACT         => 'Mutation testing for Perl that never rewrites a source file',
    AUTHOR           => 'Yasunobu Sakashita',
    VERSION_FROM     => 'lib/Permutl.pm',
    MIN_PERL_VERSION => delete $requirements{runtime}{perl},
    EXE_FILES        => ['bin/permutl'],
    PREREQ_PM        => $requirements{runtime},
    TEST_REQUIRES    => $requirements{test},
    META_MERGE       => {
        'meta-spec' => { version => 2 },
        resources   => {
            repository => { type => 'git', url => "$home.git", web => $home },
            bugtracker => { web  => "$home/issues" },
        },
    },

    # The shim adds code to the debugger package of Perl, which the index must leave to Perl.
    META_ADD => {
        license  => [ 'mit', 'apache_2_0' ],
        no_index => { directory => [ 't', 'xt' ], package => ['DB'] },
    },
    test => { TESTS => join q{ }, @tests },

    # macOS records extended attributes in the archive, and GNU tar warns about each one when it unpacks.
    dist => { TARFLAGS => '--no-xattrs -cvf' },
);
