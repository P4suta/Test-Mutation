use v5.36;
use Test2::V0;
use Permutl::Runner;

# A mutant run serves every source file through the hook, as the unmodified run does.
# The two runs then differ in the text of one file and in nothing else.

is Permutl::Runner::target_pairs( '/p', [ 'lib/A.pm', 'lib/B.pm', 'lib/C.pm' ], 'lib/B.pm', '/work/mutant.pm' ),
  [ [ '/p/lib/A.pm', '/p/lib/A.pm' ], [ '/p/lib/B.pm', '/work/mutant.pm' ], [ '/p/lib/C.pm', '/p/lib/C.pm' ] ],
  'the mutated file is served from the mutant and every other file from itself';

is Permutl::Runner::target_pairs( '/p', ['lib/A.pm'], 'lib/Z.pm', '/work/mutant.pm' ),
  [ [ '/p/lib/A.pm', '/p/lib/A.pm' ], [ '/p/lib/Z.pm', '/work/mutant.pm' ] ],
  'a mutated file outside the list is added';

like dies { Permutl::Runner::target_pairs( '/p', 'lib/A.pm', 'lib/A.pm', '/work/mutant.pm' ) },
  qr/did not pass type constraint/, 'the arguments are checked';

done_testing;
