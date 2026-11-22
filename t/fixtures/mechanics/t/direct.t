use strict;
use warnings;
use Cwd ();
use Test::More tests => 1;

require( Cwd::getcwd() . '/lib/Direct.pm' );
is Direct::quadruple(2), 8, 'quadruples';
