use v5.36;
use Test2::V0;
use File::Temp ();
use Permutl::Cache;

my $dir = File::Temp::tempdir( CLEANUP => 1 );

sub record (%fields) {
    return {
        inputs    => 'k',
        status    => 'Killed',
        reason    => undef,
        by        => 't/a.t',
        tests_run => 1,
        duration  => 0.5,
        code      => undef,
        %fields
    };
}

subtest 'a key depends on every part and on the order of the parts' => sub {
    my $key = Permutl::Cache::key( 'a', 'b' );
    like $key, qr/\A[0-9a-f]{64}\z/, 'a key is a digest';
    is Permutl::Cache::key( 'a', 'b' ),   $key,                            'equal parts give an equal key';
    isnt Permutl::Cache::key( 'a', 'c' ), $key,                            'a changed part changes the key';
    isnt Permutl::Cache::key( 'b', 'a' ), $key,                            'the order matters';
    isnt Permutl::Cache::key('ab'),       Permutl::Cache::key( 'a', 'b' ), 'parts do not run together';
    like Permutl::Cache::key("\x{3042}"), qr/\A[0-9a-f]{64}\z/, 'a part outside ASCII is accepted';
};

subtest 'records survive a round trip' => sub {
    my $path    = "$dir/nested/cache.json";
    my %records = (
        aaaaaaaaaaaa => record(),
        bbbbbbbbbbbb => record( status => 'Survived', by     => undef, code => 'c' x 64 ),
        cccccccccccc => record( status => 'Ignored',  reason => 'compiles to the same code as the original' ),
        dddddddddddd => record( status => 'CompileError' ),
    );
    is Permutl::Cache::save( $path, \%records ), 4,         'save returns the number of stored records';
    is Permutl::Cache::load($path),              \%records, 'the loaded records equal the saved records';

    open my $handle, '<', $path or die "open: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close: $!";
    unlike $text, qr/"[^"]*(?:key|token|secret|password|credential|auth)[^"]*":/i,
      'no field has a name that a secret scanner reads as a credential';
};

subtest 'a result that depends on the machine or on an unfinished run is left out' => sub {
    my $path = "$dir/partial.json";
    Permutl::Cache::save( $path,
        { map { $_ => record( status => $_ ) } qw(Killed Timeout RuntimeError NoCoverage Pending) } );
    is [ sort keys Permutl::Cache::load($path)->%* ], ['Killed'], 'the cache keeps the stable statuses';
};

subtest 'an unusable file is an empty cache' => sub {
    is Permutl::Cache::load("$dir/missing.json"), {}, 'a missing file';
    open my $handle, '>', "$dir/broken.json" or die "open: $!";
    print {$handle} '{ not json' or die "print: $!";
    close $handle                or die "close: $!";
    is Permutl::Cache::load("$dir/broken.json"), {}, 'a file that is not JSON';
    my $valid = '{"inputs":"k","status":"Killed","reason":null,"by":null,"tests_run":1,"duration":1,"code":null}';
    my %text  = (
        version => qq({"version":0,"mutants":{"aaaaaaaaaaaa":$valid}}),
        list    => '{"version":2,"mutants":[]}',
        array   => '[1]',
        record  => qq({"version":2,"mutants":{"aaaaaaaaaaaa":{"inputs":"k"},"bbbbbbbbbbbb":$valid}}),
    );
    for my $name ( sort keys %text ) {
        open $handle, '>', "$dir/$name.json" or die "open: $!";
        print {$handle} $text{$name} or die "print: $!";
        close $handle                or die "close: $!";
    }
    is Permutl::Cache::load("$dir/version.json"), {}, 'a file of another format version';
    is Permutl::Cache::load("$dir/list.json"),    {}, 'a file whose records are a list';
    is Permutl::Cache::load("$dir/array.json"),   {}, 'a file that holds a list';
    is [ keys Permutl::Cache::load("$dir/record.json")->%* ], ['bbbbbbbbbbbb'], 'a malformed record is left out';
};

done_testing;
