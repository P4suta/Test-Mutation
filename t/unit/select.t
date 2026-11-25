use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Fixture qw(write_file);
use Raised;
use Test::Mutation::Select;

my $root  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my @files = qw(lib/A.pm lib/Nested/B.pm library/C.pm);
write_file( "$root/$_", "1;\n" ) for @files, 'lib/other.txt', 'lib/Time:Now.pm';
push @files, 'lib/Time:Now.pm';
write_file( "$root/lib/Nested/lib/Again.pm", "1;\n" );
push @files, 'lib/Nested/lib/Again.pm';

sub selection (@operands) {
    return Test::Mutation::Select::paths( $root, \@operands, \@files );
}

is selection(), {}, 'no operands';
is selection( 'lib/A.pm:1-2,4', './lib/A.pm:7' ),
  { 'lib/A.pm' => [ [ 1, 2 ], [ 4, 4 ], [ 7, 7 ] ] }, 'repeated file operands combine ranges';
is selection("$root/lib/A.pm"), { 'lib/A.pm' => [] }, 'an absolute file names the same project source';
my $directory = { map { $_ => [] } @files[ 0, 1, 3, 4 ] };
is selection('lib'), $directory, 'the directory stops at a path component boundary';
is selection( 'lib/A.pm:3', 'lib' ),        $directory, 'a directory expands a previous range to the entire file';
is selection( 'lib',        'lib/A.pm:3' ), $directory, 'a range leaves a previous complete file selection intact';
is selection( 'lib/A.pm',   'lib' ), $directory, 'an already selected file leaves later directory matches eligible';
is selection(q{.}),                { map { $_ => [] } @files }, 'the project directory includes every source';
is selection('lib/Time:Now.pm'),   { 'lib/Time:Now.pm' => [] },           'an existing filename can contain a colon';
is selection('lib/Time:Now.pm:3'), { 'lib/Time:Now.pm' => [ [ 3, 3 ] ] }, 'only the final colon introduces a range';

for my $operand ( q{}, qw(absent lib/other.txt lib:1 lib/A.pm: lib/A.pm:0 lib/A.pm:1-0 lib/A.pm:3-2 lib/A.pm:x),
    'lib/A.pm:1,' )
{
    my $error = Raised::error( sub { selection($operand) } );
    is $error->[1], 'path-selector-invalid', "refuse '$operand' as a selection";
    like $error->[2], qr/\Q$operand\E/, 'the diagnostic names the input';
}

done_testing;
