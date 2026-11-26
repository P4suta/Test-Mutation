use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/lib';
use Raised;
use Test::Mutation::Settings;
use Test::Mutation::Commands;

# The table of the settings, the decoders of the three surfaces, and the resolution of the layers into a configuration.

my %row   = map { $_->name => $_ } Test::Mutation::Settings::rows()->@*;
my $facts = { processors => 4, env => {} };
my $root  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

sub write_file ( $name, $text ) {
    open my $handle, '>:encoding(UTF-8)', "$root/$name" or die "write $name: $!";
    print {$handle} $text or die "write $name: $!";
    close $handle         or die "close $name: $!";
    return;
}

sub entry ( $name, $value, $surface = 'line' ) {
    my $spelled = ( $surface eq 'file' ? 'mutation.toml: ' : q{} ) . $row{$name}->spelled($surface);
    return ( $name => { value => $value, spelled => $spelled, surface => $surface } );
}

sub layer ( $origin, %entries ) {
    return { origin => $origin, name => $origin eq 'file' ? 'mutation.toml' : undef, entries => \%entries };
}

sub resolved (@layers) {
    return Test::Mutation::Settings::resolve( root => $root, layers => \@layers, facts => $facts );
}

sub refused ($code) {
    my $error = Raised::error($code);
    return ref $error ? [ $error->@[ 1, 2 ] ] : $error;
}

sub configured ( $file, %given ) {
    unlink "$root/mutation.toml";
    write_file( 'mutation.toml', $file ) if defined $file;
    return Test::Mutation::Settings::configure( root => $root, given => layer( 'line', %given ), facts => $facts );
}

subtest 'one row for each setting, with one name on every surface' => sub {
    my @names = map { $_->name } Test::Mutation::Settings::rows()->@*;
    is scalar(@names),                                           34, 'the settings';
    is [ grep { $names[$_] eq $names[ $_ - 1 ] } 1 .. $#names ], [], 'no name twice in a row';
    my $score = $row{'min-score'};
    is [ $score->flag, $score->key, $score->attribute ], [ '--min-score', 'min-score', 'min_score' ], 'the three names';
    is [ map { $score->spelled($_) } qw(line file call) ], [ '--min-score', 'min-score', 'min_score' ],
      'the name on each surface';
    is [ map { $_->name } grep { !$_->offers('file') } values %row ], bag { item 'root'; item 'config'; end },
      'the file holds every setting but the two that find it';
    is [ grep { !$_->offers('line') || !$_->offers('call') } values %row ], [], 'and the other surfaces hold every one';
    is [ sort map { $_->name } grep { $_->selects } values %row ], [qw(mutant shard since)],
      'the settings that narrow a run';
    is [ map { $_->short // () } @row{qw(root jobs cache)} ], [ '-C', '-j' ], 'the short options';
    my @commands = Test::Mutation::Commands::rows()->@*;
    is [ map { $_->name } grep { $_->accepts('root') } @commands ], [qw(run baseline list show exec merge mutators)],
      'commands that accept a project directory';
    is [ map { $_->name } grep { $_->accepts('jobs') } @commands ], [qw(run baseline list show exec merge)],
      'commands that accept the job count';
};

subtest 'each default has the type of its setting' => sub {
    for my $setting ( grep { defined $_->default } values %row ) {
        ok $setting->value_type->check( $setting->default->($facts) ), $setting->name;
    }
    is [ sort map { $_->name } grep { !defined $_->default } values %row ], [qw(config min-score shard since)],
      'the settings without a default';
    ok $row{'min-score'}->value_type->check(undef), 'which may stay unset';
    ok !$row{jobs}->value_type->check(undef),       'and a setting with a default may not';
    ok $row{source}->value_type->check( [] ),       'a list may be empty';
    is $row{jobs}->default->( { processors => 1, env => {} } ), 1, 'one job for one processor';
    is $row{jobs}->default->( { processors => 8, env => {} } ), 7, 'and one less than the processors';
    is $row{format}->default->( { processors => 1, env => { GITHUB_ACTIONS => 'true' } } ),
      [qw(terminal json html github)], 'GitHub Actions adds its report';
    is [ map { $row{format}->default->( { processors => 1, env => { GITHUB_ACTIONS => $_ } } ) } 'false', undef ],
      [ [qw(terminal json html)], [qw(terminal json html)] ], 'and any other value leaves it out';
};

subtest 'the default of every setting and its text' => sub {
    is {
        map { $_->name => ( $_->default ? $_->default->($facts) : undef ) } values %row
    }, {
        root               => q{.},
        config             => undef,
        jobs               => 3,
        color              => 0,
        'min-score'        => undef,
        format             => [qw(terminal json html)],
        'report-dir'       => 'mutation-report',
        'threshold-high'   => 80,
        'threshold-low'    => 60,
        perl               => $^X,
        lib                => ['lib'],
        switch             => [],
        source             => [qw(lib/**/*.pm bin/**/* script/**/*)],
        'source-exclude'   => [],
        test               => ['t/**/*.t'],
        'test-exclude'     => [],
        profile            => 'default',
        enable             => [],
        disable            => [],
        equivalence        => 1,
        coverage           => 'line',
        'timeout-factor'   => 4,
        'timeout-floor'    => 10,
        'baseline-timeout' => 600,
        'in-place'         => 0,
        link               => ['local'],
        'keep-work'        => 0,
        mutant             => [],
        since              => undef,
        shard              => undef,
        cache              => 1,
        'cache-dir'        => '.mutation',

        'suppress-require-names'  => 0,
        'suppress-require-reason' => 0,
      },
      'the defaults';

    # A default that the facts leave as it is has a text that states its value.
    my $other = {
        terminal   => 1,
        processors => 9,
        env        => { GITHUB_ACTIONS => 'true' },
        launch     => { lib            => [qw(blib/lib blib/arch)], switch => [] }
    };
    my $count   = 0;
    my $text_of = sub ($value) { ref $value ? "@$value" : $value };
    for my $setting ( grep { defined $_->default } values %row ) {
        my ( $here, $there ) = map { $text_of->( $setting->default->($_) ) } $facts, $other;
        next if $here ne $there;
        my $text =
            $setting->name eq 'source' ? 'lib/**/*.pm and the Perl scripts of bin and script'
          : $setting->kind eq 'flag'   ? ( $here ? 'on' : 'off' )
          : !length $here              ? 'none'
          : $here eq $^X               ? 'the running interpreter'
          :                              $here;
        is $setting->default_text, $text, 'the text of the default of ' . $setting->name;
        $count++;
    }
    is $count, 26, 'the defaults that stay the same on the two projects';
};

subtest 'the interactions that the table declares' => sub {
    is [ map { join q{ }, $_->{rule}, $_->{settings}->@* } Test::Mutation::Settings::interactions()->@* ],
      [
        'order threshold-low threshold-high',
        'exclusive in-place link',
        'defers shard min-score',
        'updates-report mutant'
      ],
      'four interactions';
    is [ grep { !$row{$_} } map { $_->{settings}->@* } Test::Mutation::Settings::interactions()->@* ], [],
      'each names settings of the table';
};

subtest 'the nearest name' => sub {
    my @flags = qw(--jobs --root --cache --cache-dir);
    is Test::Mutation::Settings::nearest( '--jobz',     \@flags ), '--jobs',      'one letter changed';
    is Test::Mutation::Settings::nearest( '--cach',     \@flags ), '--cache',     'one letter fewer';
    is Test::Mutation::Settings::nearest( '--cache-di', \@flags ), '--cache-dir', 'one letter fewer of a longer name';
    is Test::Mutation::Settings::nearest( '--roots',    \@flags ), '--root',      'one letter more';
    is Test::Mutation::Settings::nearest( '--bobs', [qw(--jobs --robs)] ),  '--jobs', 'a tie goes to the earlier name';
    is Test::Mutation::Settings::nearest( '--rcot', [qw(--rxxt --rcat)] ),  '--rcat', 'one change beats two';
    is Test::Mutation::Settings::nearest( 'ab',     [qw(ba abc)] ),         'abc',    'an insertion beats a swap';
    is Test::Mutation::Settings::nearest( q{},      [qw(abcd ab abc)] ),    'ab',     'the shortest name from nothing';
    is Test::Mutation::Settings::nearest( 'abcd',   [qw(xbcd axcd abxd)] ), 'xbcd', 'a change at each place costs one';
};

subtest 'one value of each type' => sub {
    my $decoded = sub ( $name, $text ) {
        my $value = eval { Test::Mutation::Settings::decode( setting => $row{$name}, given => $text, spelled => 'x' ) };
        return defined $value ? $value : 'refused';
    };
    is [ map { $decoded->( 'jobs', $_ ) } 1, 16, '9007199254740992' ], [ 1, 16, 9007199254740992 ],
      'whole numbers above zero';
    is [ map { $decoded->( 'jobs', $_ ) } 0, -1, '1.5', 'x', '0x10', '9007199254740993', '99999999999999999999' ],
      [ ('refused') x 7 ], 'and nothing else, also nothing above the largest exact number';
    is [ map { $decoded->( 'timeout-factor', $_ ) } '0.5', 2, '1e3', '.5', '1e300' ], [ 0.5, 2, 1000, 0.5, 1e300 ],
      'numbers above zero';
    is [ map { $decoded->( 'timeout-factor', $_ ) } 0, -1, 'inf', 'nan', '1e400', 'x' ], [ ('refused') x 6 ],
      'and no infinity';
    is [ map { $decoded->( 'min-score', $_ ) } 0, 100, '99.5' ],          [ 0, 100, 99.5 ],    'percentages';
    is [ map { $decoded->( 'min-score', $_ ) } -1, '100.5', 'inf', 'x' ], [ ('refused') x 4 ], 'only from 0 to 100';
    is [ map { $decoded->( 'shard', $_ ) } '1/1', '2/3' ],                [ '1/1', '2/3' ],    'parts';
    is [ map { $decoded->( 'shard', $_ ) } '0/3', '4/3', '2', 'a/b' ],    [ ('refused') x 4 ], 'and nothing else';
    is [ map { $decoded->( 'coverage', $_ ) } 'line', 'file', 'branch' ], [ 'line', 'file', 'refused' ], 'a mode';
    is $decoded->( 'source', q{} ),                                       q{}, 'a glob may be empty';

    is refused( sub { Test::Mutation::Settings::decode( setting => $row{jobs}, given => '0', spelled => '-j' ) } ),
      [ 'setting-invalid', '-j takes a whole number above zero, not 0' ], 'a refusal names the spelling';
};

subtest 'the nearest layer gives the whole value' => sub {
    my $default = resolved();
    is [ $default->jobs, $default->source, $default->min_score, $default->config, $default->root ],
      [ 3, [qw(lib/**/*.pm bin/**/* script/**/*)], undef, undef, $root ], 'the defaults, from the facts of the run';
    my $file = layer( 'file', entry( 'jobs', 5, 'file' ), entry( 'source', ['src/**/*.pm'], 'file' ) );
    my $line = layer( 'line', entry( 'jobs', 2 ) );
    my $both = resolved( $file, $line );
    is [ $both->jobs, $both->source, $both->config ], [ 2, ['src/**/*.pm'], 'mutation.toml' ],
      'the line beats the file, and the file beats the default';
    is resolved( $file, layer( 'line', entry( 'source', ['lib/A.pm'] ) ) )->source, ['lib/A.pm'],
      'a list of a nearer layer replaces the whole list';
    is resolved( layer( 'line', entry( 'format', [] ) ) )->format, [], 'and an empty list too';
    is resolved( layer( 'line', entry( 'root', '/elsewhere' ), entry( 'config', 'ci.toml' ) ) )->root, $root,
      'the directory and the file come from the caller, which found them';
};

subtest 'the declared interactions' => sub {
    my $low  = layer( 'line', entry( 'threshold-low',  90 ) );
    my $high = layer( 'file', entry( 'threshold-high', 50, 'file' ) );
    is refused( sub { resolved($low) } ),
      [ 'settings-out-of-order', '--threshold-low 90 lies above --threshold-high 80 by default' ],
      'a low threshold above the default high one';
    is refused( sub { resolved($high) } ),
      [ 'settings-out-of-order', 'threshold-low 60 by default lies above mutation.toml: threshold-high 50' ],
      'a high threshold below the default low one';
    is refused( sub { resolved( layer( 'call', entry( 'threshold-high', 50, 'call' ) ) ) } ),
      [ 'settings-out-of-order', 'threshold_low 60 by default lies above threshold_high 50' ],
      'and the same from a call';
    is refused( sub { resolved( $high, $low ) } ),
      [ 'settings-out-of-order', '--threshold-low 90 lies above mutation.toml: threshold-high 50' ], 'or both set';
    is resolved( layer( 'line', entry( 'threshold-low', 80 ) ) )->threshold_low, 80, 'equal thresholds';

    my $in_place = layer( 'file', entry( 'in-place', 1, 'file' ) );
    is refused( sub { resolved( $in_place, layer( 'line', entry( 'link', ['vendor'] ) ) ) } ),
      [ 'settings-exclusive', 'mutation.toml: in-place and --link exclude each other' ],
      'the tests in the project and a link that the user names';
    is resolved($in_place)->link, ['local'], 'the default link stays with the tests in the project';
    is resolved( $in_place, layer( 'line', entry( 'in-place', 0 ), entry( 'link', ['vendor'] ) ) )->link,
      ['vendor'], 'and a link without them';
};

subtest 'the configuration file holds one key for each setting and no section' => sub {
    my $config = configured( qq{jobs = 2\nsource = ["src/**/*.pm"]\ncache = true\nmin-score = 75.5\n}
          . qq{timeout-floor = 3\nformat = []\nin-place = false\n} );
    is [ $config->jobs, $config->source, $config->cache, $config->min_score, $config->timeout_floor ],
      [ 2, ['src/**/*.pm'], 1, 75.5, 3 ], 'each type of value';
    is [ $config->format, $config->in_place, $config->config ], [ [], 0, 'mutation.toml' ], 'and the name of the file';
    is configured(qq{jobs = 1_000\n})->jobs,                    1000,                       'a number with underscores';
    is configured( qq{jobs = 2\n}, entry( 'jobs', 3 ) )->jobs,  3,     'the command line beats the file';
    is configured(undef)->config,                               undef, 'no file';

    my $refusal = sub ($text) {
        refused( sub { configured($text) } );
    };
    is $refusal->(qq{cache = "false"\n}),
      [ 'setting-invalid', 'mutation.toml: cache takes true or false, not "false"' ], 'a text for a flag';
    is $refusal->(qq{jobs = 0x10\n}),
      [ 'setting-invalid', 'mutation.toml: jobs takes a whole number above zero, not 0x10' ],
      'a hexadecimal number';
    is $refusal->(qq{jobs = 0o17\n}),
      [ 'setting-invalid', 'mutation.toml: jobs takes a whole number above zero, not 0o17' ],
      'an octal number';
    is $refusal->(qq{timeout-factor = inf\n}),
      [ 'setting-invalid', 'mutation.toml: timeout-factor takes a number above zero, not inf' ], 'infinity';
    is $refusal->(qq{timeout-factor = nan\n}),
      [ 'setting-invalid', 'mutation.toml: timeout-factor takes a number above zero, not nan' ], 'no number';
    is $refusal->(qq{timeout-floor = 1e400\n}),
      [ 'setting-invalid', 'mutation.toml: timeout-floor takes a number above zero, not 1e400' ], 'a number too large';
    is $refusal->(qq{jobs = 99999999999999999999\n}),
      [ 'setting-invalid', 'mutation.toml: jobs takes a whole number above zero, not 99999999999999999999' ],
      'a whole number too large';
    is $refusal->(qq{jobs = 2.0\n}),
      [ 'setting-invalid', 'mutation.toml: jobs takes a whole number above zero, not 2.0' ],
      'a fraction for a whole number';
    is $refusal->(qq{jobs = "2"\n}),
      [ 'setting-invalid', 'mutation.toml: jobs takes a whole number above zero, not "2"' ],
      'a text for a number';
    is $refusal->(qq{since = 1979-05-27\n}),
      [ 'setting-invalid', 'mutation.toml: since takes a Git revision, not 1979-05-27' ], 'a date';
    is $refusal->(qq{cache = 1\n}), [ 'setting-invalid', 'mutation.toml: cache takes true or false, not 1' ],
      'a number for a flag';
    is $refusal->(qq{source = "lib"\n}),
      [ 'setting-invalid', 'mutation.toml: source takes a list of globs, not "lib"' ],
      'one value for a list';
    is $refusal->(qq{source = [1, "a"]\n}),
      [ 'setting-invalid', 'mutation.toml: source takes a list of globs, not [1, "a"]' ], 'a list with a number';
    is $refusal->(qq{source = [true, 2.5]\n}),
      [ 'setting-invalid', 'mutation.toml: source takes a list of globs, not [true, 2.5]' ], 'a list of other values';
    is $refusal->(qq{source = [["a"]]\n}),
      [ 'setting-invalid', 'mutation.toml: source takes a list of globs, not [["a"]]' ], 'a list in a list';
    is $refusal->(qq{source = [{ a = 1 }]\n}),
      [ 'setting-invalid', 'mutation.toml: source takes a list of globs, not [a table]' ], 'a table in a list';
    is $refusal->(qq{jobs = ["2"]\n}),
      [ 'setting-invalid', 'mutation.toml: jobs takes a whole number above zero, not ["2"]' ],
      'a list for one value';

    is $refusal->(qq{[mutators]\nprofile = "default"\n}),
      [ 'config-section', 'mutation.toml: [mutators] is a section, and the file holds none' ], 'a section';
    is $refusal->(qq{source = { include = ["lib"] }\n}),
      [ 'config-section', 'mutation.toml: [source] is a section, and the file holds none' ], 'and an inline table';
    is $refusal->(qq{jobz = 2\n}), [ 'setting-unknown', 'mutation.toml: jobz names no setting; the nearest is jobs' ],
      'an unknown key';
    is $refusal->(qq{min_score = 2\n}),
      [ 'setting-unknown', 'mutation.toml: min_score names no setting; the nearest is min-score' ],
      'the name of another surface';
    is $refusal->(qq{root = "x"\n}),
      [ 'setting-outside-file', 'mutation.toml: root names the place of the file, so the file cannot hold it' ],
      'a setting that the file cannot hold';
    is $refusal->(qq{jobs = = 2\n})->[0], 'input-malformed', 'a text that is no configuration';

    write_file( 'ci.toml', qq{jobs = 7\n} );
    is configured( qq{jobs = 2\n}, entry( 'config', 'ci.toml' ) )->jobs, 7, 'a named file in place of mutation.toml';
    is refused( sub { configured( undef, entry( 'config', 'absent.toml' ) ) } )->[0], 'input-unreadable',
      'a named file that is absent';
};

subtest 'a call of the library' => sub {
    my $call = sub (%arguments) { Test::Mutation::Settings::of_call( { root => $root, %arguments } ) };
    unlink "$root/mutation.toml";
    my $config = $call->( jobs => 2, min_score => 50, source => ['lib/A.pm'], in_place => 1 );
    is [ $config->jobs, $config->min_score, $config->source, $config->in_place, $config->root ],
      [ 2, 50, ['lib/A.pm'], 1, $root ], 'the settings of a call';
    write_file( 'mutation.toml', qq{jobs = 3\nsource = ["src"]\n} );
    my $over = $call->( jobs => 2 );
    is [ $over->jobs, $over->source ],       [ 2, ['src'] ], 'over the file';
    is $call->( config => 'ci.toml' )->jobs, 7,              'and a named file';
    unlink "$root/mutation.toml";

    is refused( sub { $call->( jobz => 2 ) } ), [ 'setting-unknown', 'jobz names no setting; the nearest is jobs' ],
      'an unknown name';
    is refused( sub { $call->( 'min-score' => 2 ) } ),
      [ 'setting-unknown', 'min-score names no setting; the nearest is min_score' ], 'the name of another surface';
    is refused( sub { $call->( jobs => 0 ) } ), [ 'setting-invalid', 'jobs takes a whole number above zero, not 0' ],
      'a value outside the type';
    is refused( sub { $call->( source => 'lib' ) } ), [ 'setting-invalid', 'source takes a list of globs, not lib' ],
      'one value for a list';
    is refused( sub { $call->( format => [ 'json', 'pdf' ] ) } ),
      [ 'setting-invalid', 'format takes a list of terminal, json, html, and github, not [json, pdf]' ],
      'a list with a value outside the type';
    is refused( sub { $call->( jobs => [2] ) } ),
      [ 'setting-invalid', 'jobs takes a whole number above zero, not [2]' ],
      'a list for one value';
    is refused( sub { $call->( jobs => undef ) } ),
      [ 'setting-invalid', 'jobs takes a whole number above zero, not nothing' ], 'nothing';
    like dies { $call->( jobs => {} ) }, qr/HashRef/, 'and the signature of the call refuses a hash';
    is refused( sub { $call->( cache => 'yes' ) } ), [ 'setting-invalid', 'cache takes true or false, not yes' ],
      'a word for a flag';
    is refused(
        sub {
            $call->( cache => sub { 1 } );
        }
      ),
      [ 'setting-invalid', 'cache takes true or false, not code' ],
      'code for a flag';
    is Test::Mutation::Settings::of_call( {} )->root, Cwd::getcwd(), 'the directory of the process by default';
};

done_testing;
