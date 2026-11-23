use v5.36;
use Test2::V0;
use Digest::SHA        ();
use JSON::PP           ();
use JSON::Schema::Tiny ();
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture);
use Test::Mutation::Report::Json;

# The schema file is the one that the pinned release of the viewer publishes; `mise run schema` fetches it.
my $path = 'xt/schema/mutation-testing-report-schema.json';
is Digest::SHA->new(256)->addfile($path)->hexdigest, '404575e9264686dbf85c399f6531fdb489bebc3146e7e1d793b8083bc6a041ae',
  'the schema is the pinned file';

open my $handle, '<:raw', $path or die "read $path: $!";
my $schema = JSON::PP->new->decode( do { local $/ = undef; readline $handle } );

sub errors ($document) {
    my $result = JSON::Schema::Tiny::evaluate( $document, $schema );
    return [ map { "$_->{instanceLocation}: $_->{error}" } ( $result->{errors} || [] )->@* ];
}

sub report ( $result, %thresholds ) {
    return JSON::PP->new->decode( Test::Mutation::Report::Json::render( $result, high => 80, low => 60, %thresholds ) );
}

for my $fixture (qw(calc mechanics equivalent)) {
    my ($result) = run_fixture( copy_of($fixture) );
    is errors( report($result) ), [], "the report of the $fixture fixture follows the schema";
    is errors( report( $result, high => 79.5, low => 60.25 ) ), [], "fractional thresholds of $fixture stay valid";
}
is [
    sort $schema->{properties}{files}{additionalProperties}{properties}{mutants}{items}{properties}{status}{enum}->@* ],
  [qw(CompileError Ignored Killed NoCoverage Pending RuntimeError Survived Timeout)],
  'the schema and the verdict rules name the same statuses';

subtest 'the gate rejects a report that breaks the schema' => sub {
    my ($result) = run_fixture( copy_of('calc') );
    my ($file)   = sort keys report($result)->{files}->%*;
    my %broken   = (
        'an unknown status'       => sub ($document) { $document->{files}{$file}{mutants}[0]{status} = 'Dead' },
        'a line before the first' =>
          sub ($document) { $document->{files}{$file}{mutants}[0]{location}{start}{line} = 0 },
        'a fractional threshold' => sub ($document) { $document->{thresholds}{high} = 79.5 },
        'a mutant without an id' => sub ($document) { delete $document->{files}{$file}{mutants}[0]{id} },
        'a missing file table'   => sub ($document) { delete $document->{files} },
        'a version outside 1-2'  => sub ($document) { $document->{schemaVersion} = '3' },
    );
    for my $name ( sort keys %broken ) {
        my $document = report($result);
        $broken{$name}->($document);
        ok scalar( errors($document)->@* ), $name;
    }
};

done_testing;
