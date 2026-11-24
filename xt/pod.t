use v5.36;
use Test2::V0;
use File::Temp ();
use Test::Pod  ();
use lib 't/lib';
use Gate;
use Library;

# The command and every library file hold well-formed documentation that starts with a name.
# xt/symbols.t checks that the documentation names the public symbols.

sub named_ok ($file) {
    open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close $file: $!";
    return like $text, qr/^=head1 NAME\n\n\S+ - \S/m, "$file names itself and its purpose";
}

sub written ($text) {
    my $file = File::Temp->new( SUFFIX => '.pm' );
    print {$file} $text or die "write: $!";
    close $file         or die "close: $!";
    return $file;
}

subtest 'the gate rejects malformed and absent documentation' => sub {
    my $complete = written("1;\n__END__\n\n=head1 NAME\n\nExample - a shape\n\n=cut\n");
    my $unclosed = written("1;\n__END__\n\n=head1 NAME\n\nExample - a shape\n\n=over\n\n=item one\n\n=cut\n");
    my $absent   = written("1;\n");
    is Gate::outcomes( sub { Test::Pod::pod_file_ok( $complete->filename ) } ), ['pass'], 'well-formed documentation';
    is Gate::outcomes( sub { Test::Pod::pod_file_ok( $unclosed->filename ) } ), ['fail'], 'a list without its end';
    is Gate::outcomes( sub { named_ok( $complete->filename ) } ),               ['pass'], 'a name with a purpose';
    is Gate::outcomes( sub { named_ok( $absent->filename ) } ), ['fail'], 'a file without documentation';
};

my @files = ( 'bin/mutation', Library::modules()->@* );
for my $file (@files) {
    Test::Pod::pod_file_ok( $file, "$file has well-formed documentation" );
    named_ok($file);
}
Gate::checked( 'documented files', scalar @files, at_least => 33 );

done_testing;
