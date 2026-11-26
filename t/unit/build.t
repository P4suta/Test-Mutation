use v5.36;
use Test2::V0;
use Config      qw(%Config);
use File::Temp  ();
use Time::HiRes ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Raised;
use Test::Mutation::Build;
use Test::Mutation::Launch;
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Workspace;
use Test::Mutation::Workspace::Slot;

sub directory () { return File::Temp::tempdir( CLEANUP => 1 ) }

sub stamp ( $path, $seconds ) {
    Time::HiRes::utime( $seconds, $seconds, $path ) or die "utime $path: $!";
    return;
}

sub mtime ($path) { return ( Time::HiRes::stat($path) )[9] }

subtest 'a project with only an installed native extension selects its build recipe' => sub {
    my $root   = directory();
    my $object = "blib/arch/auto/Native/Native.$Config{dlext}";
    write_file( "$root/$object", 'installed' );
    my $native = Test::Mutation::Build::native($root);
    is $native, { objects => [$object], sources => [] }, 'native detection includes the installed object';
    my @calls;
    my %options = (
        root      => $root,
        native    => $native,
        perl      => $^X,
        libraries => ['lib'],
        targets   => [],
        in_place  => 0,
        run       => sub ( $where, $argv ) { push @calls, [ $where, @$argv ] }
    );
    is Test::Mutation::Build::prepare(%options), [],
      'an installed distribution without a recipe needs no build command';
    is \@calls, [], 'no command runs when the source distribution has no recipe';
    write_file( "$root/Build.PL", '1;' );
    is Test::Mutation::Build::prepare(%options), [ $^X, 'Build' ],
      'the incremental command uses the selected interpreter';
    is \@calls, [ [ $root, $^X, 'Build.PL' ], [ $root, $^X, 'Build' ] ], 'the build runs in the private directory';
};

subtest 'make compares whole seconds and never changes a linked recipe' => sub {
    for my $case (
        [ 'Makefile.PL', 1000.25, 1000.75, 0, 999 ],
        [ 'Makefile.PL', 1002.75, 1000.25, 0, 999 ],
        [ 'Makefile.PL', 1000.25, 1001.75, 0, 1000.25 ],
        [ 'Makefile.PL', 1000.25, undef,   0, 1000.25 ],
        [ 'Makefile.PL', 1002.75, 1000.25, 1, 1002.75 ],
        [ 'Build.PL',    1002.75, 1000.25, 0, 1002.75 ],
      )
    {
        my ( $recipe, $input, $makefile, $linked, $expected ) = @$case;
        my $root   = directory();
        my $source = $linked ? directory() . '/recipe' : "$root/$recipe";
        write_file( $source, "1;\n" );
        symlink $source, "$root/$recipe" or die "link $source: $!" if $linked;
        stamp( $source, $input );
        my @commands;
        my $command = Test::Mutation::Build::prepare(
            root      => $root,
            native    => { sources => [], objects => [] },
            perl      => $^X,
            libraries => ['blib/lib'],
            targets   => [],
            in_place  => 0,
            run       => sub ( $where, $argv ) {
                push @commands, [@$argv];
                if ( $argv->[-1] eq $recipe && defined $makefile ) {
                    write_file( "$where/Makefile", 'generated' );
                    stamp( "$where/Makefile", $makefile );
                }
            }
        );
        my $build = $recipe eq 'Build.PL' ? [ $^X, 'Build' ] : [ $Config{make} ];
        is $command,       $build,                       'the incremental command matches the configuration script';
        is \@commands,     [ [ $^X, $recipe ], $build ], 'configuration precedes the build';
        is mtime($source), $expected, 'only a private Makefile.PL that could trigger regeneration is aged';
    }
};

subtest 'in-place checks inspect every selected library and preserve non-library products' => sub {
    my $root    = directory();
    my @targets = qw(bin/command lib/Missing.pm lib/Current.pm);
    for my $path (qw(bin/command lib/Current.pm)) {
        write_file( "$root/$path",      "original\n" );
        write_file( "$root/blib/$path", "built\n" );
        stamp( "$root/$path",      1000.75 );
        stamp( "$root/blib/$path", 1000.25 );
    }
    my %options = (
        root      => $root,
        native    => { sources => [], objects => [] },
        perl      => $^X,
        libraries => ['blib/lib'],
        targets   => \@targets,
        in_place  => 1,
        run       => sub { die "a build started in the checkout\n" }
    );
    my $failed = Raised::error( sub { Test::Mutation::Build::prepare(%options) } );
    is $failed->[1], 'build-product-stale', 'a missing or non-library entry cannot hide a later stale library';
    like $failed->[2], qr{blib/lib/Current[.]pm}, 'the stale library names its own product';
    stamp( "$root/blib/lib/Current.pm", 1000.75 );
    is Test::Mutation::Build::prepare(%options), [], 'equally current products pass without a command';
};

subtest 'an in-place XS check matches the source to its native product' => sub {
    my $root = directory();
    write_file( "$root/Makefile.PL", '1;' );
    my $source = 'src/Value.xs';
    my $named  = "blib/arch/auto/Value/Value.$Config{dlext}";
    my $other  = "blib/arch/auto/Bundle/Bundle.$Config{dlext}";
    write_file( "$root/$_", q{} ) for $source, $named, $other;
    stamp( "$root/$source", 2000.5 );
    stamp( "$root/$named",  2000.25 );
    stamp( "$root/$other",  2000.75 );
    my $inspect = sub {
        return Test::Mutation::Build::prepare(
            root      => $root,
            perl      => $^X,
            native    => Test::Mutation::Build::native($root),
            libraries => [],
            targets   => [],
            in_place  => 1,
            run       => sub { die "the checkout started a build\n" }
        );
    };
    my $error = Raised::error($inspect);
    is $error->[1], 'build-product-stale', 'a newer unrelated object cannot stand in for a stale matching object';
    like $error->[2], qr/\Q$source\E/, 'the diagnostic identifies the XS source';
    stamp( "$root/$named", 2000.5 );
    is $inspect->(), [], 'an object with the exact source timestamp is current';
    unlink "$root/$named" or die "remove the separately named product: $!";
    is $inspect->(), [], 'a separately named distribution object can contain the XS implementation';
    stamp( "$root/$other", 2000.25 );
    is Raised::error($inspect)->[1], 'build-product-stale', 'a stale distribution object cannot supply the source';
};

subtest 'build failures report the process result and the end of its diagnostic' => sub {
    my $root      = directory();
    my $workspace = Test::Mutation::Workspace::acquire($root);
    my $config    = Test::Mutation::Settings::of_call( { root => $root } );
    my $run       = { workspace => $workspace, config => $config };
    for my $case (
        [ 'exit 0',                                                          undef ],
        [ 'exit 7',                                                          'exit 7, signal 0' ],
        [ 'kill 15, $$; sleep 10',                                           'exit 0, signal 15' ],
        [ 'sleep 20',                                                        'time limit', 1 ],
        [ 'print "build\n\nsteps"; print STDERR "last\tmessage \n"; exit 1', 'build steps last message' ],
        [ 'print "discarded", "a" x 477, "end\n"; exit 1', ( 'a' x 477 ) . 'end' ],
      )
    {
        my ( $program, $reason, $deadline ) = @$case;
        local $run->{config} = Test::Mutation::Settings::of_call( { root => $root, baseline_timeout => $deadline } )
          if defined $deadline;
        my @command = ( $^X, '-e', $program );
        my $raised  = Raised::error( sub { Test::Mutation::Runner::_build_command( $run, $root, \@command ) } );    ## no critic (Subroutines::ProtectPrivateSubs)
        if ( !defined $reason ) {
            is $raised, undef, 'a completed build proceeds';
            next;
        }
        is $raised, [ 'environment', 'build-command-failed', join( q{ }, @command ) . " failed: $reason" ],
          'the failure identifies the command and its observed cause';
    }
    {
        no warnings 'redefine';
        local *Test::Mutation::Pool::run = sub (%args) {
            $args{done}
              ->( $args{next}->(), { exit => 0, signal => 0, overflowed => 1, output => " \n", errors => q{} } );
            return;
        };
        my $raised = Raised::error( sub { Test::Mutation::Runner::_build_command( $run, $root, ['make'] ) } );    ## no critic (Subroutines::ProtectPrivateSubs)
        is $raised, [ 'environment', 'build-command-failed', 'make failed: output limit' ],
          'the output limit identifies itself even when the discarded output contained only whitespace';
    }
    ok $workspace->release(0), 'the child processes have released the build workspace';
};

subtest 'each build operation validates its arguments at the call boundary' => sub {
    my $tree   = directory();
    my $caller = __FILE__;
    for my $case (
        [ 'native',              sub { Test::Mutation::Build::native( [] ) } ],
        [ 'interpreter_options', sub { Test::Mutation::Launch::interpreter_options( $tree, [], [ {} ] ) } ],
        [ 'products',            sub { Test::Mutation::Workspace::Slot::products( $tree, [], q{} ) } ],
        [ 'twins',               sub { Test::Mutation::Workspace::Slot::twins( $tree, [], q{} ) } ],
        [ 'install', sub { Test::Mutation::Workspace::Slot::install( $tree, 'lib/Part.pm', q{}, { copy => [] } ) } ],
      )
    {
        my ( $operation, $call ) = @$case;
        my $error = dies { $call->() };
        like "$error", qr/type constraint/, "$operation rejects a malformed input";
        like "$error", qr/\bat \Q$caller\E line /,
          "$operation identifies the caller that supplied the malformed argument";
    }
};

done_testing;
