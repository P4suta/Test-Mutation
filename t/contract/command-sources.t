use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(write_file);
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Shim ();
use Test::Mutation::Workspace::Slot;

subtest 'only traced command targets publish matching installed paths' => sub {
    my $tree  = File::Temp::tempdir( CLEANUP => 1 );
    my @names = qw(lib/Product.pm script/missing bin/run script/deep/check);
    my $body  = "#!perl\nprint 2;\n";
    write_file( "$tree/$_", $body )
      for qw(lib/Product.pm blib/lib/Product.pm bin/run blib/script/run script/deep/check blib/script/check);
    my @inputs  = map { [ "$tree/$_", "$tree/$_" ] } @names;
    my $context = {
        work    => $tree,
        project => $tree,
        config  => Test::Mutation::Settings::of_call( { root => $tree, cache => 0 } ),
        witness => { 'bin/run' => { extract => 0 }, 'script/deep/check' => { extract => undef } }
    };
    like dies { Test::Mutation::Workspace::Slot::twins( $tree, [], $body ) }, qr/type constraint "Str"/,
      'an installed name must be a source path';
    for my $placed ( 0, 1 ) {
        for my $trace ( 0, 1 ) {
            local $context->{copies} = $placed ? $tree : undef;
            my $spec   = Test::Mutation::Runner::_spec( $context, $tree, 'selection', $trace, \@inputs );    ## no critic (Subroutines::ProtectPrivateSubs)
            my $parsed = Test::Mutation::Shim::read_spec($spec);
            is [ map { $_->{original} } $parsed->{targets}->@* ], [ map { "$tree/$_" } @names ],
              'every target is declared regardless of the instrumentation mode';
            is $parsed->{extract} || {}, $placed ? { "$tree/bin/run" => 1 } : {},
              'only a copied target with a defined extraction point receives the marker';
            my $wanted =
              $placed && $trace
              ? {
                "$tree/bin/run"           => ["$tree/blib/script/run"],
                "$tree/script/deep/check" => ["$tree/blib/script/check"]
              }
              : {};
            is $parsed->{commands} || {}, $wanted,
              'the command list retains the installed aliases and skips a module and a missing command';
        }
    }
};

done_testing;
