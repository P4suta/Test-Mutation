use v5.36;
use Test2::V0;
use File::Temp ();
use Test::Mutation::Cache;
use Test::Mutation::Status;

my $dir = File::Temp::tempdir( CLEANUP => 1 );

sub record (%fields) {
    return {
        inputs    => 'k',
        status    => 'Killed',
        reason    => undef,
        detail    => 't/a.t failed',
        by        => 't/a.t',
        tests_run => 1,
        duration  => 0.5,
        code      => undef,
        %fields
    };
}

sub write_text ( $name, $text ) {
    open my $handle, '>', "$dir/$name" or die "open: $!";
    print {$handle} $text or die "print: $!";
    close $handle         or die "close: $!";
    return "$dir/$name";
}

subtest 'a key depends on every part and on the order of the parts' => sub {
    my $key = Test::Mutation::Cache::key( 'a', 'b' );
    like $key, qr/\A[0-9a-f]{64}\z/, 'a key is a digest';
    is Test::Mutation::Cache::key( 'a', 'b' ),   $key, 'equal parts give an equal key';
    isnt Test::Mutation::Cache::key( 'a', 'c' ), $key, 'a changed part changes the key';
    isnt Test::Mutation::Cache::key( 'b', 'a' ), $key, 'the order matters';
    isnt Test::Mutation::Cache::key('ab'),       Test::Mutation::Cache::key( 'a', 'b' ), 'parts do not run together';
    like Test::Mutation::Cache::key("\x{3042}"), qr/\A[0-9a-f]{64}\z/, 'a part outside ASCII is accepted';
};

subtest 'records survive a round trip' => sub {
    my $path    = "$dir/nested/cache.json";
    my %records = (
        aaaaaaaaaaaa => record(),
        bbbbbbbbbbbb => record( status => 'Survived', detail => undef, by => undef, code => 'c' x 64 ),
        cccccccccccc => record(
            status => 'Ignored',
            reason => 'same-code-as-original',
            detail => 'compiles to the same code as the original',
            by     => undef
        ),
        dddddddddddd => record( status => 'CompileError', reason => 'compile-phase' ),
    );
    is Test::Mutation::Cache::save( $path, \%records ), 4,         'save returns the number of stored records';
    is Test::Mutation::Cache::load($path),              \%records, 'the loaded records equal the saved records';

    open my $handle, '<', $path or die "open: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close: $!";
    unlike $text, qr/"[^"]*(?:key|token|secret|password|credential|auth)[^"]*":/i,
      'no field has a name that a secret scanner reads as a credential';
};

subtest 'the cache keeps the statuses that the catalog marks as stable' => sub {
    my $path = "$dir/partial.json";
    my @rows = Test::Mutation::Status::rows()->@*;
    Test::Mutation::Cache::save( $path,
        { map { $_->name => record( status => $_->name, reason => $_->reasons->[0] ) } @rows } );
    is [ sort keys Test::Mutation::Cache::load($path)->%* ], [qw(CompileError Ignored Killed Survived)],
      'a result that depends on the machine or on an unfinished run is left out';
    is [ sort map { $_->name } grep { $_->cached } @rows ], [qw(CompileError Ignored Killed Survived)],
      'and the catalog names the same statuses';
};

subtest 'an unusable file is an empty cache' => sub {
    is Test::Mutation::Cache::load("$dir/missing.json"),                         {}, 'a missing file';
    is Test::Mutation::Cache::load( write_text( 'broken.json', '{ not json' ) ), {}, 'a file that is not JSON';
    my $valid = '{"inputs":"k","status":"Killed","reason":null,"detail":null,"by":null,"tests_run":1,"duration":1,'
      . '"code":null}';
    my $reasonless = $valid =~ s/"Killed"/"Timeout"/r;
    my $old        = '{"inputs":"k","status":"Killed","reason":null,"by":null,"tests_run":1,"duration":1,"code":null}';
    is Test::Mutation::Cache::load( write_text( 'version.json', qq({"version":2,"mutants":{"aaaaaaaaaaaa":$old}}) ) ),
      {}, 'a file of the earlier format, whose reasons are sentences';
    is Test::Mutation::Cache::load( write_text( 'list.json', '{"version":3,"mutants":[]}' ) ), {},
      'a file whose records are a list';
    is Test::Mutation::Cache::load( write_text( 'array.json', '[1]' ) ), {}, 'a file that holds a list';
    my $records = qq({"version":3,"mutants":{"aaaaaaaaaaaa":{"inputs":"k"},"bbbbbbbbbbbb":$valid,)
      . qq("cccccccccccc":$reasonless}});
    is [ keys Test::Mutation::Cache::load( write_text( 'record.json', $records ) )->%* ], ['bbbbbbbbbbbb'],
      'a malformed record and a record without the reason of its status are left out';
};

done_testing;
