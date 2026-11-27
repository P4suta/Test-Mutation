package Test::Mutation::Report::Html;
use v5.36;
use Encode          ();
use Types::Standard qw(CodeRef InstanceOf Num Optional Str Undef);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Report::Json;
use Test::Mutation::Report::Results;

our $VERSION = '0.001';

signature_for viewer_version => ( positional => [], returns => Str );

sub viewer_version () {
    return '3.9.0';
}

signature_for viewer_digest => ( positional => [], returns => Str );

sub viewer_digest () {
    return '751fb010242b0b44e32d84fe7fe0b9ff1da182823b94f59f5c52b001fcfc163b';
}

signature_for viewer_script => ( positional => [], returns => Str );

sub viewer_script () {
    my $path = __FILE__ =~ s{Html[.]pm\z}{resources/mutation-test-elements.js}r;
    open my $handle, '<:raw', $path or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    local $/ = undef;
    my $bytes = readline $handle;
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK );
}

signature_for render => (
    head    => [ InstanceOf ['Test::Mutation::Result'] ],
    named   => [ high => Num, low => Num ],
    returns => Str,
);

sub render ( $result, $arg ) {
    my $page = q{};
    stream( $result, high => $arg->high, low => $arg->low, write => sub ($chunk) { $page .= $chunk } );
    return $page;
}

signature_for stream => (
    head    => [ InstanceOf ['Test::Mutation::Result'] ],
    named   => [ high => Num, low => Num, write => CodeRef, write_json => Optional [CodeRef] ],
    returns => Undef,
);

sub stream ( $result, $arg ) {
    my $write  = $arg->write;
    my $viewer = viewer_script();
    my $score  = $result->tally->{score};
    my @lines  = (
        Test::Mutation::Report::Results::overview($result)->@*,
        defined $score ? sprintf( 'Score: %.1f%%', $score ) : 'Score: none',
        Test::Mutation::Report::Results::decision( $result, $result->min_score )->@*
    );
    my @paragraphs;
    for (@lines) {
        my $text = $_ =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr;
        push @paragraphs, "<p>$text</p>";
    }
    my $summary = join "\n", @paragraphs;
    $write->(<<"HTML");
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mutation report</title>
<script>$viewer</script>
</head>
<body>
<header>
<h1>Mutation report</h1>
$summary
</header>
<mutation-test-report-app title-postfix="Test::Mutation"></mutation-test-report-app>
HTML
    $write->('<script id="report" type="application/json">');
    Test::Mutation::Report::Json::stream(
        $result,
        high  => $arg->high,
        low   => $arg->low,
        write => sub ($chunk) {
            $arg->write_json->($chunk) if $arg->has_write_json;
            $write->( $chunk =~ s/</\\u003c/gr );
        }
    );
    $write->(<<'HTML');
</script>
<script>
document.querySelector('mutation-test-report-app').report = JSON.parse(document.getElementById('report').textContent);
</script>
</body>
</html>
HTML
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Report::Html - render a result as one self-contained HTML page

=head1 SYNOPSIS

    my $html = Test::Mutation::Report::Html::render( $result, high => 80, low => 60 );

=head1 DESCRIPTION

The page embeds the C<mutation-testing-elements> viewer and the report data, so it opens without a network connection.
The viewer is a build of the Stryker project under the Apache License 2.0, shipped beside this module with its license text.

=head1 FUNCTIONS

=head2 render

Returns the page as text.
Every left angle bracket in the report data is escaped, so source text cannot end the data element.

=head2 stream

Writes the viewer and the escaped report through the C<write> callback.
The optional C<write_json> callback receives the same JSON before HTML escaping.

=head2 viewer_script

Returns the text of the bundled viewer.

=head2 viewer_version

Returns the version of the bundled viewer.

=head2 viewer_digest

Returns the SHA-256 digest of the bundled viewer file.

=cut
