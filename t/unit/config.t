use v5.36;
use Test2::V0;
use Permutl::Config;

sub layers (%layers) {
    return Permutl::Config->from_layers( root => '/project', defaults => {}, file => {}, cli => {}, %layers );
}

subtest 'defaults' => sub {
    my $config = layers();
    is $config->root,             '/project',               'root';
    is $config->source_include,   ['lib/**/*.pm'],          'sources';
    is $config->test_include,     ['t/**/*.t'],             'tests';
    is $config->switches,         ['-Ilib'],                'switches';
    is $config->perl,             $^X,                      'the running interpreter';
    is $config->coverage,         'line',                   'coverage';
    is $config->profile,          'default',                'profile';
    is $config->formats,          [qw(terminal json html)], 'formats';
    is $config->report_directory, 'permutl-report',         'report directory';
    is $config->threshold_break,  undef,                    'no failing threshold';
    is $config->jobs,             1,                        'jobs';
    is $config->in_place,         0,                        'the tests run in copies of the project';
    is $config->link,             ['local'],                'the copies link the directory of installed modules';
};

subtest 'the file sets attributes through sections' => sub {
    my $config = layers(
        file => {
            jobs   => 3,
            source => { include => ['src/**/*.pm'], exclude => ['src/Gen/**'] },
            test   => {
                include          => ['xt/**/*.t'],
                switches         => [ '-Ilib', '-Mblib' ],
                'timeout-factor' => 2.5,
                coverage         => 'file',
                'in-place'       => 1,
                link             => [ 'local', 'vendor' ],
            },
            mutators   => { profile   => 'extended', disable => ['sub-body'] },
            report     => { directory => 'out',      formats => ['json'] },
            thresholds => { high      => 90,         low     => 70, break => 75 },
        },
    );
    is $config->jobs,             3,                     'jobs';
    is $config->source_include,   ['src/**/*.pm'],       'source include';
    is $config->source_exclude,   ['src/Gen/**'],        'source exclude';
    is $config->test_include,     ['xt/**/*.t'],         'test include';
    is $config->switches,         [ '-Ilib', '-Mblib' ], 'switches';
    is $config->timeout_factor,   2.5,                   'timeout factor';
    is $config->coverage,         'file',                'coverage';
    is $config->profile,          'extended',            'profile';
    is $config->disable,          ['sub-body'],          'disabled mutators';
    is $config->report_directory, 'out',                 'report directory';
    is $config->formats,          ['json'],              'formats';
    is $config->threshold_break,  75,                    'failing threshold';
    is $config->in_place,         1,                     'tests in the project itself';
    is $config->link,             [ 'local', 'vendor' ], 'linked directories';
};

subtest 'priority rises from defaults to the file to the command line' => sub {
    is layers( defaults => { jobs => 8 } )->jobs, 8, 'a default';
    is layers( defaults => { jobs => 8 }, file => { jobs => 4 } )->jobs, 4, 'the file beats the default';
    is layers( defaults => { jobs => 8 }, file => { jobs => 4 }, cli => { jobs => 2 } )->jobs, 2,
      'the command line beats the file';
};

subtest 'invalid settings are refused' => sub {
    like dies { layers( file => { speed => 1 } ) },  qr/unknown configuration key speed/,         'an unknown key';
    like dies { layers( file => { tests => {} } ) }, qr/unknown configuration section \[tests\]/, 'an unknown section';
    like dies { layers( file => { test  => { colour => 1 } } ) }, qr/unknown configuration key colour in \[test\]/,
      'an unknown key in a section';
    like dies { layers( cli  => { jobs       => 0 } ) },                qr/jobs/,            'zero jobs';
    like dies { layers( cli  => { coverage   => 'branch' } ) },         qr/coverage/,        'an unknown coverage mode';
    like dies { layers( file => { thresholds => { break => 120 } } ) }, qr/threshold_break/, 'a percentage above 100';
    like dies { layers( cli  => { threshold_break => -1 } ) },          qr/threshold_break/, 'a negative percentage';
    is layers( cli => { threshold_break => 0 } )->threshold_break,   0,   'zero percent is accepted';
    is layers( cli => { threshold_break => 100 } )->threshold_break, 100, 'one hundred percent is accepted';
    like dies { layers( cli => { formats => ['pdf'] } ) }, qr/formats/, 'an unknown format';
};

done_testing;
