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

WriteMakefile(
    NAME             => 'Permutl',
    ABSTRACT         => 'Mutation testing for Perl that leaves the source tree untouched',
    AUTHOR           => 'Yasunobu',
    VERSION_FROM     => 'lib/Permutl.pm',
    MIN_PERL_VERSION => delete $requirements{runtime}{perl},
    EXE_FILES        => ['bin/permutl'],
    PREREQ_PM        => $requirements{runtime},
    TEST_REQUIRES    => $requirements{test},
    META_MERGE       => { 'meta-spec' => { version => 2 } },
    META_ADD         => { license     => [ 'mit', 'apache_2_0' ] },
    test             => { TESTS       => 't/unit/*.t t/shim/*.t t/assumptions/*.t t/e2e/*.t' },
);
