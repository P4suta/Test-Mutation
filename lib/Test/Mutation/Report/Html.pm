package Test::Mutation::Report::Html;
use v5.36;
use Encode          ();
use JSON::PP        ();
use Types::Standard qw(InstanceOf Num Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Report::Json;

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
    open my $handle, '<:raw', $path or die "cannot read $path: $!\n";
    local $/ = undef;
    my $bytes = readline $handle;
    close $handle or die "cannot close $path: $!\n";
    return Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK );
}

signature_for render => (
    head    => [ InstanceOf ['Test::Mutation::Result'] ],
    named   => [ high => Num, low => Num ],
    returns => Str,
);

sub render ( $result, $arg ) {
    my $document = Test::Mutation::Report::Json::document( $result, high => $arg->high, low => $arg->low );
    my $data     = JSON::PP->new->canonical->encode($document) =~ s/</\\u003c/gr;
    my $viewer   = viewer_script();
    return <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mutation report</title>
<script>$viewer</script>
</head>
<body>
<mutation-test-report-app title-postfix="permutl"></mutation-test-report-app>
<script id="report" type="application/json">$data</script>
<script>
document.querySelector('mutation-test-report-app').report = JSON.parse(document.getElementById('report').textContent);
</script>
</body>
</html>
HTML
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

=head2 viewer_script

Returns the text of the bundled viewer.

=head2 viewer_version

Returns the version of the bundled viewer.

=head2 viewer_digest

Returns the SHA-256 digest of the bundled viewer file.

=cut
