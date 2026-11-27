use v5.36;
use Test2::V0;
use Encode ();
use lib 't/contract/lib', 't/e2e/lib';
use Fixture qw(copy_of write_file);
use Samples;
use World;
use Test::Mutation::Report::Html;
use Test::Mutation::Report::Json;
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $root     = copy_of('calc');
my $config   = Test::Mutation::Settings::of_call( { root => $root } );
my $selected = Test::Mutation::Select::resolve( config => $config );
my $sources  = { map { $_ => $selected->sources->{$_}->text } keys $selected->sources->%* };
my ( $recent, $earlier ) = $selected->mutants->@*;
my $directory = "$root/mutation-report";

sub saved_report ( $status, @mutants ) {
    my $sample = Samples::result( statuses => [$status] )->entries->[0];
    my @entries;
    push @entries, { $sample->%*, mutant => $_ } for @mutants;
    return Samples::result( root => $root, sources => $sources, entries => \@entries );
}

my $full   = saved_report( 'Killed',   $selected->mutants->@* );
my $narrow = saved_report( 'Survived', $recent );
my $json   = Test::Mutation::Report::Json::render( $full, high => 80, low => 60 );
write_file( "$directory/mutation.json", $json );
write_file( "$directory/mutation.html",
    Encode::encode( 'UTF-8', Test::Mutation::Report::Html::render( $narrow, high => 80, low => 60 ) ) );
utime 1, 1, "$directory/mutation.json" or die "date the earlier report: $!";
is scalar Test::Mutation::Report::Json::parse($json)->entries->@*, scalar $selected->mutants->@*,
  'the earlier report records the full source selection';
my $parse = \&Test::Mutation::Report::Json::parse;

sub observed (@arguments) {
    my $reads = 0;
    no warnings 'redefine';
    local *Test::Mutation::Report::Json::parse = sub ($text) { $reads++; return $parse->($text) };
    my $result = World::observe( \@arguments, cwd => $root );
    is $result->{exit}, 0, 'the saved result command succeeded';
    return ( $result->{stdout}, $reads );
}

my ( $shown, $reads ) = observed( 'show', $recent->id );
like $shown, qr/^Last result: Survived$/m, 'the selected mutant uses the most recent matching observation';
is $reads, 1, 'one reported mutant in the newest shard satisfies show';
( $shown, $reads ) = observed( 'show', $earlier->id );
like $shown, qr/^Last result: Killed$/m, 'a mutant missing from the newest shard finds its earlier verdict';
is $reads, 2, 'the missing mutant requires the other saved format';
my ( $recent_id, $earlier_id ) = map { $_->id } $recent, $earlier;
my ( $listed, $list_reads ) = observed('list');
like $listed, qr/^\Q$recent_id\E  .*  \[Survived\] 1970-01-01T00:01:41Z$/m, 'the newer verdict and its date';
like $listed, qr/^\Q$earlier_id\E  .*  \[Killed\] 1970-01-01T00:01:41Z$/m,  'the earlier mutant and its date';
is $list_reads, 2, 'listing every mutant needs both complementary reports';
write_file( "$directory/mutation.html",
    Encode::encode( 'UTF-8', Test::Mutation::Report::Html::render( $full, high => 80, low => 60 ) ) );
( $listed, $list_reads ) = observed('list');
unlike $listed, qr/\[Survived\]/, 'a complete newer measurement supplies every listed verdict';
is $list_reads, 1, 'a complete current report satisfies list without decoding the older format';

subtest 'a failed or narrower first measurement preserves observations in earlier report files' => sub {
    write_file( "$root/t/fail.t", "use Test::More tests => 1;\nfail 'original';\n" );
    my @args = ( 'run', '--jobs', 1, '--format', 'terminal' );
    is World::observe( \@args, cwd => $root )->{exit}, 3, 'the original suite fails';
    my ( $shown, $reads ) = observed( 'show', $earlier_id );
    like $shown, qr/^Last result: Killed$/m, 'a failed baseline leaves the last measured verdict visible';
    unlink "$root/t/fail.t" or die "unlink failing test: $!";
    is World::observe( [ @args, '--mutant', $recent_id ], cwd => $root )->{exit}, 0, 'one mutant is remeasured';
    ( $shown, $reads ) = observed( 'show', $earlier_id );
    like $shown, qr/^Last result: Killed$/m, 'a different mutant still finds its historical report';
    ( $shown, $reads ) = observed( 'show', $recent_id );
    is $reads, 0, 'the indexed mutant needs no reports';
    ( $listed, $list_reads ) = observed('list');
    like $listed, qr/^\Q$earlier_id\E .* \[Killed\]/m, 'listing combines indexed and earlier observations';
    is $list_reads, 1, 'one complete historical report supplies the outstanding identifiers';
};

my $pending = saved_report( 'Pending', $earlier );
write_file( "$directory/mutation.html",
    Encode::encode( 'UTF-8', Test::Mutation::Report::Html::render( $pending, high => 80, low => 60 ) ) );
( $shown, $reads ) = observed( 'show', $earlier_id );
like $shown, qr/^Last result: Killed$/m, 'an unfinished report entry preserves the earlier measured verdict';

done_testing;
