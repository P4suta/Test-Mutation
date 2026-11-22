package Permutl::Report::Patch;
use v5.36;
use Types::Standard qw(InstanceOf Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my $CONTEXT = 2;

signature_for render => (
    named   => [ text => Str, mutant => InstanceOf ['Permutl::Mutant'] ],
    returns => Str,
);

sub render ($arg) {
    my $mutant  = $arg->mutant;
    my $mutated = $arg->text;
    substr $mutated, $mutant->start, $mutant->end - $mutant->start, $mutant->replacement;
    my @old = split /\n/, $arg->text, -1;
    my @new = split /\n/, $mutated, -1;

    my $prefix = 0;
    $prefix++ while $prefix < @old && $prefix < @new && $old[$prefix] eq $new[$prefix];
    my $suffix = 0;
    $suffix++
      while $suffix < @old - $prefix && $suffix < @new - $prefix && $old[ -1 - $suffix ] eq $new[ -1 - $suffix ];

    my @removed = @old[ $prefix .. $#old - $suffix ];
    my @added   = @new[ $prefix .. $#new - $suffix ];
    my $first   = $prefix > $CONTEXT ? $prefix - $CONTEXT : 0;
    my $resume  = @old - $suffix;
    my $lines   = $old[-1] eq q{}                     ? @old - 1               : scalar @old;
    my $final   = $resume + $CONTEXT - 1 < $lines - 1 ? $resume + $CONTEXT - 1 : $lines - 1;
    my @before  = @old[ $first .. $prefix - 1 ];
    my @after   = $resume <= $final ? @old[ $resume .. $final ] : ();

    my $path = $mutant->path;
    return join q{}, map { "$_\n" } "--- $path", "+++ $path",
      sprintf( '@@ -%d,%d +%d,%d @@', $first + 1, @before + @removed + @after, $first + 1, @before + @added + @after ),
      ( map { " $_" } @before ),
      ( map { "-$_" } @removed ),
      ( map { "+$_" } @added ),
      ( map { " $_" } @after );
}

1;

__END__

=head1 NAME

Permutl::Report::Patch - render a mutant as a unified diff

=head1 SYNOPSIS

    print Permutl::Report::Patch::render( text => $source_text, mutant => $mutant );

=head1 FUNCTIONS

=head2 render

Returns the change a mutant makes to its file as a unified diff with two lines of context.

=cut
