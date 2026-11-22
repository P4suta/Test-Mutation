use strict;
use warnings;
use Test::More;
use Calc;

ok Calc::is_positive(5),   'five is positive';
ok !Calc::is_positive(-5), 'minus five is not positive';
is Calc::describe(-3), 'negative', 'describes a negative number';
is Calc::describe(4),  'positive', 'describes a positive number';

done_testing;
