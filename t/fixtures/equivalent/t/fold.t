use strict;
use warnings;
use Test::More tests => 2;
use Fold;

is Fold::minute(), 60, 'a minute has sixty seconds';
ok defined Fold::label(1), 'a count has a label';
