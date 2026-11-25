package Test::Mutation::Suppression;
use v5.36;
use Types::Standard qw(ArrayRef Bool Dict InstanceOf Int Maybe Str Tuple);
use Type::Params    qw(signature_for);
use Test::Mutation::Message;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Types qw(Directive Refusal Suppression);

our $VERSION = '0.001';

# A comment that resembles a directive must have the canonical form, so a misspelt directive never suppresses in silence.
my $CANDIDATE = qr/\A\s*[#]+\s*(?:no|use)\s*mutat/i;
my $VERB      = qr/[#][#][ ](no|use)[ ]mutate([ ]sub)?/;
my $NAMES     = qr/(?:[ ][(]([a-z-]+(?:,[ ][a-z-]+)*)[)])?/;
my $REASON    = qr/(?:[:][ ](.+))?/;
my $CANONICAL = qr/\A$VERB$NAMES$REASON\z/;
my %KNOWN     = map { $_->name => 1 } Test::Mutation::Mutator::Catalog::mutators()->@*;

my $COMMENT = Dict [ line => Int, own => Bool, text => Str, routine => Maybe [ Tuple [ Int, Int ] ] ];

signature_for parse => ( named => [ path => Str, comments => ArrayRef [$COMMENT] ], returns => Suppression );

sub parse ($arg) {
    my $path = $arg->path;
    my ( @directives, @refusals, $open );
    for my $comment ( grep { $_->{text} =~ $CANDIDATE } $arg->comments->@* ) {
        my ( $line, $text ) = $comment->@{qw(line text)};
        my ( $verb, $sub, $list, $reason ) = $text =~ $CANONICAL;
        my @names   = split /,[ ]/, defined $list ? $list : q{};
        my @unknown = grep { !$KNOWN{$_} } @names;
        my %at      = ( path => $path, line => $line );
        if ( !_placed( $verb, $sub, $list, $reason, $comment->{own} ) ) {
            push @refusals,
              _refusal( $line, 'suppression-malformed',
                Test::Mutation::Message::text_of( 'suppression-malformed', %at, comment => $text ) );
            next;
        }
        if (@unknown) {
            push @refusals,
              _refusal( $line, 'suppression-mutator-unknown',
                Test::Mutation::Message::text_of( 'suppression-mutator-unknown', %at, names => join q{, }, @unknown ) );
            next;
        }
        if ( $verb eq 'use' ) {
            push @refusals,
              _refusal( $line, 'suppression-end-unopened',
                Test::Mutation::Message::text_of( 'suppression-end-unopened', %at ) )
              if !$open;
            $open->{last} = $line if $open;
            $open = undef;
            next;
        }
        my $routine = $comment->{routine};
        if ( $sub && !$routine ) {
            push @refusals,
              _refusal( $line, 'suppression-sub-missing',
                Test::Mutation::Message::text_of( 'suppression-sub-missing', %at ) );
            next;
        }
        my $opens = $comment->{own} && !$sub;
        if ( $opens && $open ) {
            push @refusals,
              _refusal( $line, 'suppression-block-nested',
                Test::Mutation::Message::text_of( 'suppression-block-nested', %at, open => $open->{line} ) );
            next;
        }
        my ( $first, $last ) = $sub ? $routine->@* : ( $line, $opens ? undef : $line );
        push @directives,
          {
            line   => $line,
            text   => $text,
            first  => $first,
            last   => $last,
            names  => @names ? \@names : undef,
            reason => $reason
          };
        $open = $directives[-1] if $opens;
    }
    push @refusals,
      _refusal( $open->{line}, 'suppression-block-unclosed',
        Test::Mutation::Message::text_of( 'suppression-block-unclosed', path => $path, line => $open->{line} ) )
      if $open;
    return { directives => \@directives, refusals => \@refusals };
}

# An end stands on a line of its own and alone, and a comment that names a subroutine stands on a line of its own.
sub _placed ( $verb, $sub, $list, $reason, $own ) {
    return 0 if !defined $verb;
    return $own && !$sub && !defined $list && !defined $reason ? 1 : 0 if $verb eq 'use';
    return $own || !$sub ? 1 : 0;
}

sub _refusal ( $line, $id, $text ) {
    return { line => $line, id => $id, text => $text };
}

sub _covers ( $directive, $line, $mutator ) {
    my ( $first, $last, $names ) = $directive->@{qw(first last names)};
    return 0 if $line < $first || ( defined $last && $line > $last );
    return !$names             || ( grep { $_ eq $mutator } $names->@* ) ? 1 : 0;
}

signature_for covering => ( positional => [ ArrayRef [Directive], Int, Str ], returns => Maybe [Directive] );

sub covering ( $directives, $line, $mutator ) {
    my @covering = grep { _covers( $_, $line, $mutator ) } $directives->@*;
    return $covering[-1];
}

signature_for refusals => (
    named => [
        path          => Str,
        suppression   => Suppression,
        mutants       => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ],
        require_names => Bool,
        { default => 0 },
        require_reason => Bool,
        { default => 0 },
    ],
    returns => ArrayRef [Refusal],
);

sub refusals ($arg) {
    my $suppression = $arg->suppression;
    my @refusals    = ( $suppression->{refusals}->@*, map { _checked( $arg, $_ ) } $suppression->{directives}->@* );
    return [ sort { $a->{line} <=> $b->{line} } @refusals ];
}

# The refusals of one directive that the grammar accepted: the names and the reason that the call asks for, and its use.
sub _checked ( $arg, $directive ) {
    my $line = $directive->{line};
    my %at   = ( path => $arg->path, line => $line, comment => $directive->{text} );
    my $used = grep { _covers( $directive, $_->from->[0], $_->mutator ) } $arg->mutants->@*;
    return (
        $arg->require_names && !$directive->{names} ? _refusal(
            $line, 'suppression-names-missing',
            Test::Mutation::Message::text_of( 'suppression-names-missing', %at )
          )
        : (),
        $arg->require_reason && !defined $directive->{reason} ? _refusal(
            $line, 'suppression-reason-missing',
            Test::Mutation::Message::text_of( 'suppression-reason-missing', %at )
          )
        : (),
        !$used ? _refusal( $line, 'suppression-unused', Test::Mutation::Message::text_of( 'suppression-unused', %at ) )
        : (),
    );
}

1;

__END__

=head1 NAME

Test::Mutation::Suppression - read the comments that suppress mutants

=head1 SYNOPSIS

    my $suppression = Test::Mutation::Suppression::parse(
        path     => 'lib/Calc.pm',
        comments => [ { line => 7, own => 0, text => '## no mutate (arithmetic)', routine => undef } ],
    );
    my $directive = Test::Mutation::Suppression::covering( $suppression->{directives}, 7, 'arithmetic' );
    my $refusals  = Test::Mutation::Suppression::refusals(
        path        => 'lib/Calc.pm',
        suppression => $suppression,
        mutants     => $mutants,
    );

=head1 DESCRIPTION

The comments that suppress mutants follow one grammar of three forms.
C<## no mutate> behind code covers the mutants that start on its line.
C<## no mutate> on a line of its own opens a block that C<## use mutate> on a line of its own closes.
C<## no mutate sub> on a line of its own covers the named subroutine or method that follows, with its signature and its body.
Each form may name mutators, as in C<## no mutate (arithmetic, comparison)>, and a reason may follow a colon and a space, as in C<## no mutate (arithmetic): the sum is a constant>.
The names narrow the form to the mutants of those mutators, and the reason stays with every mutant that the comment covers.

A candidate is a comment that matches C</\A\s*#+\s*(?:no|use)\s*mutat/i>.
Each candidate in another form than the grammar is refused, and so is an unknown name, an end without an open block, a second block inside an open one, a block that the file leaves open, and a comment with C<sub> before another statement.
A refused comment suppresses nothing, and the reader goes on to the end of the file, so a run reports every refusal at once.

=head1 FUNCTIONS

=head2 parse

Returns the L<Test::Mutation::Types/Suppression> of a file from the facts of each comment.
C<line> is the line of the comment, and C<own> is true for a comment on a line of its own.
C<text> starts at the first hash sign and ends before the trailing blanks.
C<routine> holds the first and the last line of the named subroutine or method that starts at the next token, or nothing.

=head2 covering

Returns the directive that covers a mutant on the given line of the given mutator, or nothing.
Among several, the one whose comment comes last wins, which is the most specific one.

=head2 refusals

Returns the refusals of the grammar together with every directive that covers none of the mutants, in the order of their lines.
C<path> names the file in the text of each refusal.
C<require_names> refuses a directive without names, and C<require_reason> refuses a directive without a reason.

=cut
