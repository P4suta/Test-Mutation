package Test::Mutation::Types;
use v5.36;
use Type::Library -base, -declare => qw(Analysis Dropped Facts Heredoc Names Rejected Suppression);
use Type::Utils     qw(as declare);
use Types::Standard qw(ArrayRef Bool Dict Enum InstanceOf Int Maybe Num Optional Str Tuple);

our $VERSION = '0.001';

declare Facts,
  as Dict [
    right       => Optional [Num],
    version     => Optional [Num],
    settled     => Optional [Bool],
    operand     => Optional [ Enum [qw(match substitute transliterate dynamic)] ],
    keyword     => Optional [Str],
    head        => Optional [Str],
    name        => Optional [Str],
    literal     => Optional [Str],
    declares    => Optional [Bool],
    final_value => Optional [Bool],
  ];

declare Dropped, as Dict [ line => Int, kind => Enum [qw(span regex)], reason => Str ];

declare Suppression, as Dict [ first => Int, last => Maybe [Int], names => Maybe [ ArrayRef [Str] ] ];

declare Heredoc, as Tuple [ Int, Int, Int, Int ];

declare Names,
  as Dict [
    imports  => ArrayRef [ Dict [ module => Str, names => ArrayRef [Str] ] ],
    declared => ArrayRef [Str],
  ];

declare Rejected,
  as Dict [
    mutator => Str,
    line    => Int,
    rule    => Enum [qw(same-text line-count here-document declaration final-value unresolved-call same-result)],
  ];

declare Analysis,
  as Dict [
    sites        => ArrayRef [ InstanceOf ['Test::Mutation::Site'] ],
    suppressions => ArrayRef [Suppression],
    dropped      => ArrayRef [Dropped],
    heredocs     => ArrayRef [Heredoc],
    names        => Names,
    problem      => Maybe [Str],
  ];

1;

__END__

=head1 NAME

Test::Mutation::Types - the types that the analysis and its readers share

=head1 SYNOPSIS

    use Test::Mutation::Types qw(Analysis Facts);

    signature_for analyze => ( positional => [ InstanceOf ['Test::Mutation::Source'] ], returns => Analysis );

=head1 DESCRIPTION

The analysis of a source file and the generator of mutants agree on one shape of the result.
A type that two modules name lives here, so a change of the shape reaches both.

C<Facts> holds what the analysis learned about a site beyond its text: the number on the right of an operator,
the version in a comparison with C<$]>, the kind of the operand of a match, the keyword of a condition,
the first word of a statement, the name of a subroutine, and the literal of a return.

C<declares> marks a span with a declaration that later code names.
C<final_value> marks a statement of the file that is a value alone, as the true value that ends a module is.

C<Dropped> names a place that the analysis left out, with its line, its kind, and the reason.

C<Suppression> is a range of lines that a C<## no mutate> comment covers, with the mutators it names.

C<Heredoc> holds four offsets of a here-document: the start and the end of its introducer, and the start and the end of its text with the line that ends it.

C<Names> holds the subroutine names that the file resolves: each C<use> statement with its module and the names it imports, and the names the file declares.
The statements stay apart because each one imports into the scope where it stands.

C<Rejected> names a change that the generator refused, with the mutator, the line, and the rule.

C<Analysis> is the result for one file: the sites, the suppressions, the places left out, the here-documents, the names, and the problem that kept the whole file from the analysis.

=cut
