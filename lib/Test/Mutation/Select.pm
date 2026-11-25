package Test::Mutation::Select;
use v5.36;
use Cwd             ();
use File::Spec      ();
use Types::Standard qw(ArrayRef Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Types qw(PathSelection);

our $VERSION = '0.001';

sub _refuse ( $path, $reason ) {
    return Test::Mutation::Error::raise( 'path-selector-invalid', path => $path, reason => $reason );
}

sub _ranges ( $operand, $lines ) {
    my @ranges;
    for my $part ( split /,/, $lines, -1 ) {
        my ( $first, $last ) = $part =~ /\A([1-9][0-9]*)(?:-([1-9][0-9]*))?\z/;
        _refuse( $operand, 'expected a positive line or ascending line range' ) if !defined $first;
        $last = $first                                                          if !defined $last;
        _refuse( $operand, 'the last line precedes the first' )                 if $last < $first;
        push @ranges, [ 0 + $first, 0 + $last ];
    }
    return \@ranges;
}

signature_for paths => ( positional => [ Str, ArrayRef [Str], ArrayRef [Str] ], returns => PathSelection );

sub paths ( $root, $operands, $sources ) {
    my %selected;
    for my $operand ( $operands->@* ) {
        my ( $path, $lines ) = ($operand);
        ( $path, $lines ) = ( $1, $2 ) if !-e File::Spec->rel2abs( $path, $root ) && $operand =~ /\A(.+):([^:]*)\z/;
        my $absolute = File::Spec->rel2abs( $path, $root );
        _refuse( $operand, 'the path does not exist' ) if !length $path || !-e $absolute;
        my $relative  = File::Spec->abs2rel( Cwd::abs_path($absolute), $root );
        my $directory = -d $absolute;
        _refuse( $operand, 'a line range needs a file' ) if defined $lines && ( $directory || !length $lines );
        my $ranges = defined $lines ? _ranges( $operand, $lines ) : [];
        my @matches =
          grep { $_ eq $relative || ( $directory && ( $relative eq q{.} || index( $_, "$relative/" ) == 0 ) ) }
          $sources->@*;
        _refuse( $operand, 'no selected source matches the path' ) if !@matches;

        for my $file (@matches) {
            next                  if exists $selected{$file} && !$selected{$file}->@*;
            $selected{$file} = [] if !$ranges->@*;
            push $selected{$file}->@*, $ranges->@* if $ranges->@*;
        }
    }
    return \%selected;
}

1;

__END__

=head1 NAME

Test::Mutation::Select - resolve source path and line operands against a project

=head1 SYNOPSIS

    my $paths = Test::Mutation::Select::paths( $root, ['lib/Adder.pm:7,10-12'], $sources );

=head1 FUNCTIONS

=head2 paths

Returns the selected source paths and their inclusive line ranges.
An empty list for a selected file covers every line.
Directory operands include all matching sources below them.
An invalid operand raises a usage error before the run starts.

=cut
