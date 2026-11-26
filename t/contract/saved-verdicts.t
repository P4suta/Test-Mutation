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
like $listed, qr/^\Q$recent_id\E  .*  \[Survived\]$/m, 'the earlier report cannot replace the newer verdict';
like $listed, qr/^\Q$earlier_id\E  .*  \[Killed\]$/m,  'the listing also finds the earlier mutant';
is $list_reads, 2, 'listing every mutant needs both complementary reports';
write_file( "$directory/mutation.html",
    Encode::encode( 'UTF-8', Test::Mutation::Report::Html::render( $full, high => 80, low => 60 ) ) );
( $listed, $list_reads ) = observed('list');
unlike $listed, qr/\[Survived\]/, 'a complete newer measurement supplies every listed verdict';
is $list_reads, 1, 'a complete current report satisfies list without decoding the older format';

done_testing;
