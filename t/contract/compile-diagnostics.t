use v5.36;
use Test2::V0;
use lib 't/lib';
use Judge;
use Test::Mutation::Attribution;

my $valid = "use strict;\nsub result { return 42 }\n1;\n";
my $parse = "use strict;\nsub result { return ( }\n1;\n";
my $load  = "BEGIN { die qq{initialization failed\\n} }\n1;\n";
my $judge = Judge::start();
for my $case (
    [ $valid, $valid, 'ok' ],
    [ $valid, $parse, 'parse' ],
    [ $valid, $load,  'compile-phase' ],
    [ $load,  $valid, 'standalone' ],
    [ $load,  $parse, 'standalone' ],
  )
{
    my ( $before, $after, $expected ) = @$case;
    my $original = Judge::reference($before);
    my $changed  = Judge::compiled( $judge, $after );
    is Test::Mutation::Attribution::compilation( $original, $changed->{compiled}, $changed->{diagnostics}, q{-} ),
      $expected, 'the classification follows the original compiler and the changed compiler';
}
ok Judge::stop($judge), 'all compiler observations were collected';
like dies { Test::Mutation::Attribution::compilation( 1, 0, [], 'module.pm', undef ) },
  qr/type constraint "Str"/, 'the classifier requires diagnostic text from the compiler';
like dies { Test::Mutation::Attribution::compilation( 1, 0, q{}, 'module.pm', 'some line' ) },
  qr/type constraint/, 'the end of a changed BEGIN block must be a line number';

done_testing;
