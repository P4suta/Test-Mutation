use strict;
use warnings;
use Test::More tests => 2;
use Fold;

is Fold::size(), 'big', 'ten is big';
ok defined Fold::label(1), 'a count has a label';
