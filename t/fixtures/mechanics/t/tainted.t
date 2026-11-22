#!perl -T
use strict;
use warnings;
use Test::More tests => 2;
use Tainted;

ok ${^TAINT}, 'taint mode is on';
is Tainted::double(4), 8, 'doubles';
