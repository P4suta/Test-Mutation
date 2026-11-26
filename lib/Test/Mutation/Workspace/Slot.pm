package Test::Mutation::Workspace::Slot;
use v5.36;
use Cwd             ();
use File::Basename  ();
use File::Spec      ();
use File::Temp      ();
use Types::Standard qw(ArrayRef Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Source;
use Test::Mutation::Try;

our $VERSION = '0.001';

signature_for place => ( positional => [ Str, Str, Str, Str ], returns => ArrayRef [Str] );

sub place ( $root, $path, $original, $mutant ) {
    my %replace = ( $path => $mutant );
    my @copies  = ("blib/$path");
    push @copies, "blib/script/$1" if $path =~ m{\Abin/(.+)\z};
    for my $copy (@copies) {
        next unless -f "$root/$copy";
        my $built = Test::Mutation::Source::read_bytes("$root/$copy");
        if ( $built eq $original ) {
            $replace{$copy} = $mutant;
        }
        elsif ( $copy =~ m{\Ablib/(?:bin|script)/} ) {
            my ( $head, $body ) = $built =~ /\A([#]![^\n]*\n)(.*)\z/s;
            my $source = $original =~ s/\A[#]![^\n]*\n//r;
            $replace{$copy} = $mutant =~ s/\A[#]![^\n]*\n/$head/r if defined $body && $body eq $source;
        }
    }
    my @paths = ( $path, sort grep { $_ ne $path } keys %replace );
    for my $file (@paths) {
        _replace( $root, $file, $replace{$file} );
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

=head2 place

Replaces the source and matching built copies with the supplied bytes and returns their relative paths.
The replacement preserves executable and read-only modes.
A built script can retain its installed interpreter line.

=cut
