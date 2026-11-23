use strict;
use warnings;
use Test::More;
use Test::Pod ();
use Pod::Coverage;

# Every library file has well-formed documentation, and every public subroutine and attribute is documented.

my @files = sort grep { -f } 'bin/mutation',
  glob 'lib/Test/Mutation.pm lib/Test/Mutation/*.pm lib/Test/Mutation/*/*.pm';
ok scalar(@files) > 10, 'library files exist';

for my $file (@files) {
    Test::Pod::pod_file_ok( $file, "$file has well-formed documentation" );
    next if $file !~ m{\Alib/(.*)[.]pm\z};
    ( my $package = $1 ) =~ s{/}{::}g;
    my $coverage = Pod::Coverage->new( package => $package, private => [qr/\A_/] );
    my $rating   = $coverage->coverage;
    if ( !defined $rating ) {
        is $coverage->why_unrated, 'no public symbols defined', "$package has no public symbol to document";
        next;
    }
    is_deeply [ sort $coverage->uncovered ], [], "$package documents every public subroutine and attribute";
}

done_testing;
