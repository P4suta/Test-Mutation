package Test::Mutation::Mutant::Validity;
use v5.36;
use Moo;
use Encode          ();
use Types::Standard qw(ArrayRef Enum InstanceOf Maybe ScalarRef Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Mutator::Providers;
use Test::Mutation::Types qw(Heredoc Names);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

has text     => ( is => 'ro', isa => Str, required => 1 );
has heredocs => ( is => 'ro', isa => ArrayRef [Heredoc], required => 1 );
has names    => ( is => 'ro', isa => Names, required => 1 );

# Perl finds a place in a long decoded text by a walk from its start.
# Four bytes hold every character of this copy, so a place in the text is a place in the bytes.
has _wide => (
    is       => 'ro',
    isa      => ScalarRef [Str],
    init_arg => undef,
    lazy     => 1,
    default  => sub ($self) {
        my $bytes = Encode::encode( 'UTF-32LE', $self->text );
        return \$bytes;
    },
);

my $SITE = InstanceOf ['Test::Mutation::Site'];

signature_for change => ( method => 1, positional => [ $SITE, Str ], returns => Maybe [Str] );

sub change ( $self, $site, $replacement ) {
    my ( $from, $removed, $written ) = ( $site->start, $site->text, $replacement );
    return if $written eq $removed;

    # What both texts share at their start and at their end is no part of the change.
    my $head = _shared( $removed, $written );
    ( $removed, $written ) = map { substr $_, $head } $removed, $written;
    my $tail = _shared( scalar reverse($removed), scalar reverse $written );
    ( $removed, $written ) = map { substr $_, 0, length($_) - $tail } $removed, $written;
    $from += $head;

    # A text removed or written beside a copy of itself has more than one place, and the last place names it.
    if ( !length $removed || !length $written ) {
        my $slide = _shared( $self->_read( $from, length $written ), $written );
        $slide += $self->_run( $from, length( $removed . $written ) ) if $slide == length $written;
        $written = substr $written . $self->_read( $from, $slide ), $slide;
        $from += $slide;
    }
    return join "\0", $from, length $removed, $written;
}

sub _read ( $self, $from, $length ) {
    return Encode::decode( 'UTF-32LE', substr $self->_wide->$*, 4 * $from, 4 * $length );
}

# The number of characters that two texts share from their start.
sub _shared ( $one, $other ) {
    my $count = 0;
    for my $character ( split //, $other ) {
        last if $character ne substr $one, $count, 1;
        $count++;
    }
    return $count;
}

# The number of characters from a place on that each equal the character one period later.
sub _run ( $self, $from, $period ) {
    my $gap  = 4 * ( $period - 1 );
    my $wide = $self->_wide;
    pos( $wide->$* ) = 4 * $from;
    my ($run) = $wide->$* =~ /\G((?:(.{4})(?=.{$gap}\2))*)/s;
    my $bytes = length $run;
    return $bytes / 4;
}

signature_for refusal => (
    method     => 1,
    positional => [ $SITE, Str ],
    returns    => Maybe [ Enum [qw(line-count here-document declaration final-value)] ],
);

sub refusal ( $self, $site, $replacement ) {
    return 'line-count' if ( $replacement =~ tr/\n// ) != ( $site->text =~ tr/\n// );
    my ( $start, $end ) = ( $site->start, $site->end );

    # A here-document is the two ends of its introducer and the two ends of its text, which follows that line.
    # A span that touches one of the two without taking both leaves text behind as code, or a string without its text.
    return 'here-document' if grep {
          !( $start <= $_->[0] && $_->[3] <= $end )
        && ( ( $start < $_->[1] && $end > $_->[0] ) || ( $start < $_->[3] && $end > $_->[2] ) )
    } $self->heredocs->@*;
    return 'declaration' if $site->facts->{declares};
    return 'final-value' if $site->facts->{final_value};
    return;
}

signature_for resolved_call => ( method => 1, positional => [ Str, Str ], returns => Maybe [Str] );

sub resolved_call ( $self, $called, $name ) {
    my ( $package, $word ) = $called =~ /\A(?:(.+)::)?(\w+)\z/;
    return if !defined $word;
    if ( defined $package ) {
        return Test::Mutation::Mutator::Providers::provides( $package, $name ) ? "${package}::$name" : undef;
    }

    # A use statement imports into the scope where it stands, and the analysis keeps no scopes.
    # The other name is in reach of the call when every statement that imports the original imports it too.
    my @imports   = $self->names->{imports}->@*;
    my @importing = grep { _lists( $_, $word ) } @imports;
    if (@importing) {
        return $name if !grep { !_lists( $_, $name ) } @importing;
        my ($module) =
          grep { Test::Mutation::Mutator::Providers::provides( $_, $name ) } map { $_->{module} } @importing;
        return defined $module ? "${module}::$name" : undef;
    }
    return
      if !Test::Mutation::Mutator::Providers::is_core($word) || !Test::Mutation::Mutator::Providers::is_core($name);

    # Perl warns about a bare core function whose name a subroutine of the file or an import shares.
    my $shared = ( grep { $_ eq $name } $self->names->{declared}->@* ) || grep { _lists( $_, $name ) } @imports;
    return $shared ? "CORE::$name" : $name;
}

sub _lists ( $import, $name ) {
    return scalar grep { $_ eq $name } $import->{names}->@*;
}

1;

__END__

=head1 NAME

Test::Mutation::Mutant::Validity - the rules that every mutant of a file passes

=head1 SYNOPSIS

    my $rules = Test::Mutation::Mutant::Validity->new(
        text     => $source->text,
        heredocs => $analysis->{heredocs},
        names    => $analysis->{names},
    );
    my $change = $rules->change( $site, q{} );
    my $rule   = $rules->refusal( $site, q{} );
    my $call   = $rules->resolved_call( 'any', 'all' );

=head1 DESCRIPTION

A mutant is a change of the source text, and a test detects it by its behavior.
A change that keeps the file from compiling or from loading has no behavior to detect, and a run would count its failure as a detected mutant.
The generator puts every change that a mutator proposes before these rules, so no mutator keeps a guard of its own.

The rules take a span as the analysis gives it.
The analysis builds every span from the tokens of the parser and counts a token whose place holds another text, so a span begins and ends at the edge of a token.

=head1 ATTRIBUTES

=head2 text

The text of the file.

=head2 heredocs

The here-documents of the file, as L<Test::Mutation::Types/Heredoc> describes them.

=head2 names

The subroutine names that the file resolves, as L<Test::Mutation::Types/Names> describes them.

=head1 METHODS

=head2 change

    my $change = $rules->change( $site, $replacement );

Returns a text that names the change by what it leaves behind, or nothing for a change that leaves the file as it was.
Two changes of one file share the text exactly when they leave the same file, whatever spans they replace.
The generator refuses the change without a name as C<same-text> and the second change of a name as C<same-result>.

=head2 refusal

    my $rule = $rules->refusal( $site, $replacement );

Returns the name of the rule that refuses the change, or nothing.
C<line-count> refuses a change that adds or removes a line, which would move every later line.
C<here-document> refuses a change that touches the introducer of a here-document or its text without taking both whole.
C<declaration> refuses the change of a span that declares a variable which later code names.
C<final-value> refuses a change of a statement that is a value alone, as the true value that ends a module is.

=head2 resolved_call

    my $call = $rules->resolved_call( $word, $name );

Returns the text that calls the function C<$name> in place of the call C<$word>, or nothing when the file resolves no such name.
A qualified call keeps its package.
A name stays bare when every C<use> statement that imports the original imports it too, so the two share every scope.
Another imported name gets the first module of those statements that provides it in front.
A core function replaces a core function, under the name C<CORE::> when a subroutine of the file or an import shares its name.
A subroutine that the file declares and a name of unknown origin have no counterpart.

=cut
