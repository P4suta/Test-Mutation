package Test::Mutation::Types;
use v5.36;
use Type::Library -base,
  -declare => qw(Analysis Dropped Entry Facts Heredoc Names Reason Rejected StatusName Suppression);
use Type::Utils     qw(as declare where);
use Types::Standard qw(ArrayRef Bool Dict Enum InstanceOf Int Maybe Num Optional Str Tuple);
use Test::Mutation::Status;

our $VERSION = '0.001';

declare StatusName, as Enum [ Test::Mutation::Status::names()->@* ];

declare Reason, as Enum [ map { $_->reasons->@* } Test::Mutation::Status::rows()->@* ];

declare Entry,
  as Dict [
    mutant     => InstanceOf ['Test::Mutation::Mutant'],
    status     => StatusName,
    reason     => Maybe [Reason],
    detail     => Maybe [Str],
    by         => Maybe [Str],
    covered_by => ArrayRef [Str],
    tests_run  => Int,
    duration   => Num,
  ],
  where { Test::Mutation::Status::fits( $_->{status}, $_->{reason} ) };

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
    branches    => Optional [ Tuple [ Int, Int ] ],
    loose       => Optional [Bool],
    anchors     => Optional [ ArrayRef [ Tuple [ Int, Int ] ] ],
  ];

declare Dropped, as Dict [ line => Int, kind => Enum [qw(span regex conditional)], reason => Str ];

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

    use Type::Params          qw(signature_for);
    use Test::Mutation::Types qw(Analysis);

    signature_for count => ( positional => [Analysis] );

    sub count ($analysis) { return scalar $analysis->{sites}->@* }

=head1 DESCRIPTION

The analysis of a source file and the generator of mutants agree on one shape of the result.
A type that two modules name lives here, so a change of the shape reaches both.

C<Facts> holds what the analysis learned about a site beyond its text: the number on the right of an operator,
the version in a comparison with C<$]>, the kind of the operand of a match, the keyword of a condition,
the first word of a statement, the name of a subroutine, and the literal of a return.

C<declares> marks a span with a declaration that later code names.
C<final_value> marks a statement of the file that is a value alone, as the true value that ends a module is.
C<branches> holds the length of the first branch of a conditional and the place where its second branch starts, both counted from the start of the span.
C<loose> marks a first branch that holds an operator looser than the conditional, as an assignment, which needs parentheses in the place of the second branch.
C<anchors> holds the places of the tokens that name the construct of a span wider than a token, such as the question mark and the colon of a conditional or the keyword of a condition.

C<Dropped> names a place that the analysis left out, with its line, its kind, and the reason.
A conditional operator without its colon or its second branch is such a place.

C<Suppression> is a range of lines that a C<## no mutate> comment covers, with the mutators it names.

C<Heredoc> holds four offsets of a here-document: the start and the end of its introducer, and the start and the end of its text with the line that ends it.

C<Names> holds the subroutine names that the file resolves: each C<use> statement with its module and the names it imports, and the names the file declares.
The statements stay apart because each one imports into the scope where it stands.

C<Rejected> names a change that the generator refused, with the mutator, the line, and the rule.

C<Analysis> is the result for one file: the sites, the suppressions, the places left out, the here-documents, the names, and the problem that kept the whole file from the analysis.

C<StatusName> is the name of a status of L<Test::Mutation::Status>, and C<Reason> is a reason that some status may carry.
C<Entry> is the result of one mutant: the mutant, its status, the reason that its status calls for, a sentence about the case, the deciding test, the selected tests, the number of tests that ran, and the time they took.
The verdict, the result, the reports, and the cache share these types, so a status outside the catalog or a reason of another status fails at the first of them.

=cut
