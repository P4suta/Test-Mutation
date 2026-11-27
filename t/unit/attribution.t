use v5.36;
use Test2::V0;
use Test::Mutation::Attribution;

my $file  = '/a project/changed.pm';
my @cases = (
    [ 1, 1, q{},                                                                                      'ok' ],
    [ 0, 1, q{},                                                                                      'standalone' ],
    [ 0, 0, "syntax error at $file line 2",                                                           'standalone' ],
    [ 1, 0, "syntax error at $file line 2, near \"+ }\"\n$file had compilation errors.\n",            'parse' ],
    [ 1, 0, "Unmatched [ in regex at $file line 2.\n",                                                'parse' ],
    [ 1, 0, "syntax error at $file line 2.\nBEGIN failed--compilation aborted at $file line 2.\n",    'compile-phase' ],
    [ 1, 0, "broken\nUNITCHECK failed--call queue aborted.\n",                                        'compile-phase' ],
    [ 1, 0, "Can't locate Needed.pm in \@INC at $file line 3.\nBEGIN failed--compilation aborted.\n", 'compile-phase' ],
    [ 1, 0, q{},                                                                                      'compile-phase' ],
);
for my $case (@cases) {
    my ( $original, $passed, $diagnostic, $expected ) = @$case;
    is Test::Mutation::Attribution::compilation( $original, $passed, $diagnostic, $file ), $expected,
      "Perl reports $expected for [$diagnostic]";
}
my $binding = qq{Bareword "OPTION" not allowed while "strict subs" in use at $file line 12.\n};
is Test::Mutation::Attribution::compilation( 1, 0, $binding, $file, 5 ), 'compile-phase',
  'changing an earlier BEGIN block stopped it from installing a constant';
is Test::Mutation::Attribution::compilation( 1, 0, $binding, $file, 12 ), 'parse',
  'an invalid bareword at the replacement remains a generator defect';
is Test::Mutation::Attribution::compilation( 1, 0, $binding, $file ), 'parse',
  'a syntax diagnostic without a changed BEGIN has no evidence of a lost binding';

done_testing;
