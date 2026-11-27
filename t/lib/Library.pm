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

# The corpus holds source text that the analysis reads as it stands.
# A fixture project fixes the lines and columns that its tests name.
my $INPUT = qr{\At/(?:corpus|fixtures)/};

# The kind of a tracked file: a library module, a program, an input of a test, or nothing for a file without Perl.
sub kind ( $path, $first_line ) {
    my $perl = $path =~ m{(?:[.](?:pm|pl|t|psgi|PL)|(?:\A|/)cpanfile)\z} || $first_line =~ /\A[#]!.*\bperl\b/;
    return if !$perl;
    return $path =~ $INPUT ? 'input' : $path =~ m{\Alib/} ? 'library' : 'program';
}

sub _first_line ($path) {
    open my $handle, '<:raw', $path or die "read $path: $!";
    my $line = readline $handle;
    close $handle or die "close $path: $!";
    return defined $line ? $line : q{};
}

# Every file that Git tracks or would track, by its kind.
sub perl_files () {
    open my $list, q{-|}, 'git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z' or die "git: $!";
    my @paths = sort split /\0/, do { local $/ = undef; readline $list };
    close $list or die "git ls-files failed\n";
    my %files = ( library => [], program => [], input => [] );
    for my $path ( grep { -f } @paths ) {
        my $kind = kind( $path, _first_line($path) ) or next;
        push $files{$kind}->@*, $path;
    }
    return \%files;
}

1;
