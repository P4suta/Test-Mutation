use v5.36;
use Test2::V0;
use File::Temp ();
use File::Glob qw(bsd_glob);
use lib 't/e2e/lib';
use Fixture qw(write_file);
use Test::Mutation::Mutant;
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Witness;
use Test::Mutation::Workspace;

my $root   = File::Temp::tempdir( CLEANUP => 1 );
my $path   = 'lib/Example.pm';
my $prefix = "package Example;\nsub value { ";
my $span   = '1; 2';
my $suffix = " }\n1;\n";
my $source = Test::Mutation::Source->new( path => $path, text => "$prefix$span$suffix", encoding => 'UTF-8' );
my $start  = length $prefix;
my $end    = $start + length $span;
my $change = Test::Mutation::Mutant->new(
    id          => '123456abcdef',
    path        => $path,
    start       => $start,
    end         => $end,
    original    => $span,
    replacement => '42',
    mutator     => 'sub-body',
    description => 'return a different value',
    scope       => [ 2, 2 ],
    from        => $source->position_of($start),
    to          => $source->position_of($end),
);
write_file( "$root/$path", $source->text );
my $workspace = Test::Mutation::Workspace::acquire($root);
my $run       = {
    root      => $root,
    project   => $root,
    config    => Test::Mutation::Settings::of_call( { root => $root } ),
    workspace => $workspace,
    targets   => [$path],
    sources   => { $path => $source },
};
## no critic (Subroutines::ProtectPrivateSubs)
Test::Mutation::Runner::_prepare_work($run);
Test::Mutation::Runner::_prepare_witnesses($run);
my $descriptor = fileno $run->{task_descriptor};
my $records    = "$run->{work}/records";
my $seen       = Test::Mutation::Witness::insert( q{}, 0, $run->{generation}, 0, $records, $descriptor );
my $name       = 'Example::replacement';
my $binding    = Test::Mutation::Witness::binding( $name, $run->{generation}, "$root/$path", $records, $descriptor );
my $changed    = $prefix . '42' . $suffix;

subtest 'binding and compilation observations remain at their own statement boundaries' => sub {
    for my $case (
        [ undef,      undef,  $changed ],
        [ 0,          undef,  $seen . $changed ],
        [ $start,     undef,  $prefix . $seen . '42' . $suffix ],
        [ $start + 1, undef,  $prefix . $seen . '42' . $suffix ],
        [ $end,       undef,  $prefix . '42' . $seen . $suffix ],
        [ undef,      0,      $binding . $changed ],
        [ $end,       0,      $binding . $prefix . '42' . $seen . $suffix ],
        [ 0,          0,      $seen . $binding . $changed ],
        [ 0,          $start, $seen . $prefix . $binding . '42' . $suffix ],
      )
    {
        my ( $witness_at, $call_at, $expected ) = @$case;
        local $run->{witness}{$path} = defined $witness_at ? { index => 0, offset => $witness_at } : undef;
        my $mutant =
          Test::Mutation::Mutant->new( %$change, introduced_call => defined $call_at ? [ $name, $call_at ] : undef );
        is Test::Mutation::Runner::_observed_bytes( $run, $source, $mutant, $root, $changed ), $expected,
          'both markers preserve their location across the length-changing replacement';
    }
};

subtest 'the unmodified checkout, compiler input and served bytes remain distinct' => sub {
    for my $raw ( 0, 1 ) {
        my ( $file, $spec ) = Test::Mutation::Runner::_write_mutant( $run, $source, $change, $root, $raw );
        my ($served) = Test::Mutation::Source::read_bytes($spec) =~ /^target\t[^\t]+\t([^\t\n]+)/m;
        is Test::Mutation::Source::read_bytes($file), $changed, 'the standalone compiler receives just the replacement';
        my $observed = Test::Mutation::Source::read_bytes($served);
        if ($raw) {
            is $served,   $file,    'a raw invocation reads the compiler input directly';
            is $observed, $changed, 'the raw command sees no observations';
        }
        else {
            isnt $served, $file, 'a measured invocation has its own instrumented source';
            like $observed, qr/\Q$seen\E/, 'the served file carries the compilation witness';
        }
        is Test::Mutation::Source::read_bytes("$root/$path"), $source->text,
          'the checkout still holds the original source';
    }
};
subtest 'a bareword fails parsing inside a replacement and loses a binding only beyond the changed BEGIN' => sub {
    my $text   = "BEGIN {\n    our \$flag = 1;\n}\nsub number { return OPTION }\n1;\n";
    my $before = Test::Mutation::Source->new( path => $path, text => $text, encoding => 'UTF-8' );
    my $file   = "$root/changed.pm";
    for my $case ( [ 'our', 4, 'parse' ], [ 'our', 5, 'compile-phase' ], [ 'return', 9, 'parse' ] ) {
        my ( $token, $reported_line, $expected ) = @$case;
        my $at     = index $text, $token;
        my $mutant = Test::Mutation::Mutant->new(
            %$change,
            start       => $at,
            end         => $at + length $token,
            original    => $token,
            replacement => "1;\n2;\n3",
            from        => $before->position_of($at),
            to          => $before->position_of( $at + length $token )
        );
        my $context = { sources => { $path => $before }, original_compile => { $path => { passed => 1 } } };
        my $job     = { mutant  => $mutant, file => $file, outcome => {} };
        my $error   = qq{Bareword "OPTION" not allowed while "strict subs" in use at $file line $reported_line.\n};
        Test::Mutation::Runner::_after_syntax(
            $context, {},
            { payload => { kind => 'syntax-mutant', job => $job } },
            { exit    => 255, errors => $error }
        );
        is [ $job->{syntax}, $job->{outcome}{syntax} ], [ $expected, $expected ],
          'the changed source line and replacement length determine the retained compiler diagnosis';
    }
};
## use critic

subtest 'a binding without a reserved descriptor writes only to the directory of its generation' => sub {
    my $fallback = File::Temp::tempdir( CLEANUP => 1 );
    my $observed = File::Temp::tempdir( CLEANUP => 1 );
    my $probe    = Test::Mutation::Witness::binding( $name, 9, $path, $fallback, undef );
    {
        delete local $ENV{TEST_MUTATION_RECORD_G9};
        is system( $^X, '-e', $probe . '1;' ), 0,  'a program without observation settings compiles normally';
        is [ glob "$fallback/call-*.rec" ],    [], 'the program never guesses a fallback record destination';
    }
    {
        local $ENV{TEST_MUTATION_RECORD_G9} = $observed;
        is system( $^X, '-e', $probe . '1;' ), 0, 'the program runs with a generation-specific record directory';
        my @records = bsd_glob("$observed/call-*.rec");
        is scalar @records, 1, 'both observations belong to the same process';
        is Test::Mutation::Source::read_bytes( $records[0] ),
          "seen\t$path\tunresolved\nseen\t$path\tunresolved-at-exit\n", 'the missing name was checked at both phases';
    }
    isa_ok dies { Test::Mutation::Witness::binding( 'not a Perl name', 9, $path, $fallback, undef ) },
      ['Error::TypeTiny'], 'the public binding probe requires a qualified Perl name';
};

ok $workspace->release(0), 'the measurement releases its records and descriptor';
done_testing;
