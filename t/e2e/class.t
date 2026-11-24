use v5.36;
use Test2::V0;
use lib 't/e2e/lib', 't/lib';
use Capability;
use Fixture qw(copy_of run_fixture statuses);

Capability::need( 'class', $] >= 5.038, 'the fixture needs the class syntax of Perl 5.38' );

my ($result) = run_fixture( copy_of('counter') );

is statuses($result),
  {
    'lib/Counter.pm:6 replaced + with -'          => 'Survived',
    'lib/Counter.pm:8 removed the body of ADJUST' => 'Survived',
    'lib/Counter.pm:9 removed the statement'      => 'Survived',
    'lib/Counter.pm:9 replaced + with -'          => 'Survived',
    'lib/Counter.pm:12 removed the body of bump'  => 'Killed',
    'lib/Counter.pm:13 removed the statement'     => 'Killed',
    'lib/Counter.pm:13 replaced += with -='       => 'Killed',
    'lib/Counter.pm:14 removed the return value'  => 'Killed',
    'lib/Counter.pm:17 removed the body of count' => 'Killed',
    'lib/Counter.pm:17 removed the return value'  => 'Killed',
    'lib/Counter.pm:19 removed the body of limit' => 'NoCoverage',
    'lib/Counter.pm:19 removed the return value'  => 'NoCoverage',
    'lib/Counter.pm:21 removed the body of size'  => 'Killed',
    'lib/Counter.pm:21 removed the return value'  => 'Killed',
    'lib/Counter.pm:21 replaced > with <='        => 'Killed',
    'lib/Counter.pm:21 replaced > with >='        => 'Ignored',
  },
  'a change in a field or an ADJUST block survives, and a change in a method compares its compiled code';
is $result->warnings, [], 'no warning';

done_testing;
