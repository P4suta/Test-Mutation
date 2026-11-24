use v5.36;
use Test2::V0;
use Test2::API ();
use lib 't/lib';
use Capability;
use Gate;

# A test that needs a command or an interpreter skips itself where the need is unmet.
# A job names the capabilities it must have, so a skip there fails and no test goes missing without notice.

subtest 'a present capability runs the test' => sub {
    is Capability::decision( 'git', 1, q{} ),     'run', 'no requirement';
    is Capability::decision( 'git', 1, 'git' ),   'run', 'a requirement that is met';
    is Capability::decision( 'git', 1, 'class' ), 'run', 'another requirement';
};

subtest 'an absent capability skips the test unless the job requires it' => sub {
    is Capability::decision( 'git', 0, q{} ),                       'skip', 'no requirement';
    is Capability::decision( 'git', 0, 'class,second-perl' ),       'skip', 'other requirements';
    is Capability::decision( 'git', 0, 'git' ),                     'fail', 'the one requirement';
    is Capability::decision( 'git', 0, 'class,git' ),               'fail', 'one of several requirements';
    is Capability::decision( 'git', 0, 'class, git ,second-perl' ), 'fail', 'spaces around a name';
    is Capability::decision( 'git', 0, 'class,,' ),                 'skip', 'an empty name between commas';
};

subtest 'a requirement must be a known capability' => sub {
    like dies { Capability::decision( 'git', 1, 'git,gti' ) }, qr/\ATEST_MUTATION_REQUIRE names no capability: gti/,
      'a misspelt requirement is refused';
    like dies { Capability::decision( 'gti', 1, q{} ) }, qr/\Ano capability is named gti/, 'a misspelt need is refused';
};

subtest 'one case of a test runs where the capability is present' => sub {
    local $ENV{TEST_MUTATION_REQUIRE} = 'class';
    my $ran = 0;
    is Gate::outcomes( sub { $ran++ if Capability::has( 'git', 1, 'the case needs git' ) } ), [], 'no assertion';
    is $ran,                                                                                  1,  'and the case runs';
    my $events = Test2::API::intercept { $ran++ if Capability::has( 'git', 0, 'the case needs git' ) };
    is $ran,                        1,                      'an absent capability leaves the case out';
    is [ map { ref } $events->@* ], ['Test2::Event::Skip'], 'and reports a skip';
    is $events->[0]->reason,        'the case needs git',   'with its reason';

    local $ENV{TEST_MUTATION_REQUIRE} = 'git';
    like dies { Capability::has( 'git', 0, 'the case needs git' ) },
      qr/\ATEST_MUTATION_REQUIRE lists git, and the case needs git/, 'a required capability that is absent fails';
};

done_testing;
