use strict;
use warnings;
use Test::More tests => 1;
use Startup;

is Startup::limit(), 10, 'the limit';
