package Test::Mutation::Workspace::Slot;
use v5.36;
use Cwd             ();
use File::Basename  ();
use File::Spec      ();
use File::Temp      ();
use List::Util      qw(uniq);
use Types::Standard qw(ArrayRef HashRef Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Source;
use Test::Mutation::Try;

our $VERSION = '0.001';

signature_for twins => ( positional => [ Str, Str, Str ], returns => HashRef [Str] );

sub twins ( $root, $path, $original ) {
    my %headers;
    my @copies = ("blib/$path");
    if ( $path =~ m{\A(?:bin|script)/(.+)\z} ) {
        my $relative = $1;
        push @copies, "blib/script/$relative", 'blib/script/' . File::Basename::basename($relative);
    }
    for my $copy ( uniq @copies ) {
        next unless -f "$root/$copy";
        my $built = Test::Mutation::Source::read_bytes("$root/$copy");
        if ( $built eq $original ) {
            $headers{$copy} = q{};
        }
        elsif ( $copy =~ m{\Ablib/(?:bin|script)/} ) {
            my ( $head, $body ) = $built =~ /\A([#]![^\n]*\n)(.*)\z/s;
            my $source = $original =~ s/\A[#]![^\n]*\n//r;
            $headers{$copy} = $head if defined $body && $body eq $source && $original =~ /\A[#]!/;
        }
    }
    return \%headers;
}

signature_for place => ( positional => [ Str, Str, Str, Str ], returns => ArrayRef [Str] );

sub place ( $root, $path, $original, $mutant ) {
    my $headers = twins( $root, $path, $original );
    my @paths   = ( $path, sort keys %$headers );
    for my $file (@paths) {
        my $bytes = $mutant;
        $bytes =~ s/\A[#]![^\n]*\n/$headers->{$file}/ if $headers->{$file};
        _replace( $root, $file, $bytes );
    }
    return \@paths;
}

sub _replace ( $root, $relative, $bytes ) {
    my $path   = "$root/$relative";
    my $parent = File::Basename::dirname($path);
    my $real   = Cwd::abs_path($parent);
    my $within = defined $real ? File::Spec->abs2rel( $real, Cwd::abs_path($root) ) : '..';
    Test::Mutation::Error::raise(
        'file-unwritable',
        path   => $path,
        reason => 'target directory is outside the job copy'
    ) if $within =~ m{\A[.][.](?:/|\z)};
    my @stat = stat $path;
    Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" ) unless @stat;
    my $made =
      Test::Mutation::Try::attempt( sub { File::Temp->new( TEMPLATE => '.mutation-XXXXXX', DIR => $parent ) } );
    Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$made->{error}" )
      if exists $made->{error};
    my $output = $made->{value};
    binmode $output;
    print {$output} $bytes or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
    chmod $stat[2] & oct '7777', $output->filename
      or Test::Mutation::Error::raise( 'file-mode-unsettable', path => $path, reason => "$!" );
    close $output or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    rename $output->filename, $path
      or Test::Mutation::Error::raise( 'file-unrenamable', path => $path, reason => "$!" );
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Workspace::Slot - install a mutation in a private job tree

=head1 FUNCTIONS

=head2 twins

Returns the relative paths of matching built files and any replacement interpreter line installed by the build.

=head2 place

Replaces the source and matching built copies with the supplied bytes and returns their relative paths.
The replacement preserves executable and read-only modes.
A built script can retain its installed interpreter line.

=cut
