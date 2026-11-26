use v5.36;
use Test2::V0;
use File::Temp ();
use POSIX      ();
use Test::Mutation::Report::Json;
use lib 't/e2e/lib';
use Fixture qw(ran write_file);

my $project = File::Temp::tempdir( CLEANUP => 1 );
write_file( "$project/lib/Totals.pm", 'package Totals; sub sum { return $_[0] + $_[1] } 1;' );
write_file( "$project/t/value.t",     "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 0), 4;\n" );
my @options = ( '--format', 'json', '--format', 'html', '--jobs', 1 );
my $files   = "$project/mutation-report";

sub report ( $format, $path = "$files/mutation.$format" ) {
    open my $file, '<:encoding(UTF-8)', $path or die $!;
    my $text = do { local $/ = undef; readline $file };
    close $file or die $!;
    if ( $format eq 'html' ) {
        ($text) = $text =~ m{<script id="report" type="application/json">(.+?)</script>}s;
    }
    return Test::Mutation::Report::Json::parse($text);
}

ran( 0, $project, @options );
my $whole = report('json');
my %first = map { $_->{mutant}->id => $_->{status} } $whole->entries->@*;
my ($id)  = grep { $first{$_} eq 'Survived' } sort keys %first;
ok defined $id, 'the original suite misses a change';
write_file( "$project/t/stronger.t", "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 1), 5;\n" );
ran( 0, $project, @options, '--mutant', $id );
$first{$id} = 'Killed';

for my $format (qw(json html)) {
    my $saved = report($format);
    is {
        map { $_->{mutant}->id => $_->{status} } $saved->entries->@*
    }, \%first, "a narrow run updates the selected verdict in the complete $format report";
    is $saved->selection->{mutants}, [$id], 'the most recent selection survives serialization';
}

unlink "$files/mutation.json" or die $!;
ran( 0, $project, '--format', 'html', '--jobs', 1, 'lib/Totals.pm:1' );
is scalar report('html')->entries->@*, scalar keys %first, 'an HTML-only update preserves the matching report';
write_file( "$project/lib/Other.pm", 'package Other; sub product { return $_[0] * 2 } 1;' );
ran( 0, $project, @options, '--mutant', $id );
is [ map { $_->{mutant}->id } report('json')->entries->@* ], [$id],
  'a changed source inventory starts a separate report';

my $link = "$files/mutation.json";
unlink $link or die $!;
my $published = "$project/published.json";
write_file( $published, "previous publication\n" );
chmod oct('640'), $published or die "set report permissions: $!";
symlink '../published.json', $link or die "link the report: $!";
ran( 0, $project, '--format', 'json', '--jobs', 1, '--mutant', $id );
is readlink($link), '../published.json', 'publishing through a relative symlink preserves the link';
is( ( stat $published )[2] & oct('777'), oct('640'), 'the published file retains the existing access permissions' );
is [ map { $_->{mutant}->id } report( 'json', $published )->entries->@* ], [$id],
  'the symlink target receives the completed measurement';

unlink $link or die $!;
symlink $project, $link or die $!;
my $rejected = ran( 5, $project, '--format', 'json', '--jobs', 1 );
like $rejected->{stderr}, qr/cannot write .*mutation[.]json/, 'the diagnostic names the report linked to a directory';
ok -l $link && -d $project, 'a non-file report destination retains its identity';

unlink $link                      or die $!;
POSIX::mkfifo( $link, oct '600' ) or die $!;
ran( 5, $project, '--format', 'json', '--jobs', 1 );
ok -p $link, 'a named pipe is never replaced by a regular report';

done_testing;
