package Library;
use v5.36;
use File::Find ();

# A glob of a fixed depth leaves a module one directory deeper outside every gate, so the gates walk the tree.
sub _files ( $root, $suffix ) {
    my @files;
    File::Find::find( { no_chdir => 1, wanted => sub { push @files, $File::Find::name if -f && /\Q$suffix\E\z/ } },
        $root );
    return [ sort @files ];
}

sub modules ( $root = 'lib' ) {
    return _files( $root, '.pm' );
}

sub tests ($root) {
    return _files( $root, '.t' );
}

sub package_of ( $path, $root = 'lib' ) {
    return substr( $path, 1 + length $root ) =~ s{[.]pm\z}{}r =~ s{/}{::}gr;
}

1;
