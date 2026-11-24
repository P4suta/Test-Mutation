use v5.36;
use Test2::V0;
use List::Util qw(min sum0);
use lib 't/lib';
use Census;
use Gate;
use Library;
use Oracle;
use Test::Mutation::Project;

# Every construct that the corpus shows is either mutated or left alone for a stated reason.
# The census reads the files with PPI on its own, so a construct that the analysis of the tool never reports still counts.

sub census_of ($code) {
    return Census::summary(
        [ map { [ 'lib/Sample.pm', $_->@* ] } Census::records( Oracle::text_source( 'lib/Sample.pm', $code ) ) ] );
}

subtest 'a token has the key of its construct' => sub {
    my $code = <<'CODE';
my $x = -$y + 3 - 1;
my %h = ( shift => 1, -bare => 2 );
$o->push( 0x10, 1.5, 1e3, 0b11, 0644 );
if ( $x <=> $#list ) { print "a", 'b', q{c}, qq{d}, qw(e f), <<'EOT' }
text
EOT
elsif ( !$x ) { return +1 }
my $r = $s =~ m/^a+$/i ? qr/b/ : $s =~ s/c/d/r;
$s =~ tr/a/b/;
print -e $path;
CODE
    is [ sort keys census_of($code)->{observed}->%* ],
      [
        sort 'ArrayIndex',
        'HereDoc',
        'Number',
        'Number::Binary',
        'Number::Exp',
        'Number::Float',
        'Number::Hex',
        'Number::Octal',
        'Quote::Double',
        'Quote::Interpolate',
        'Quote::Literal',
        'Quote::Single',
        'QuoteLike::Regexp',
        'QuoteLike::Words',
        'Regexp::Match',
        'Regexp::Substitute',
        'Regexp::Transliterate',
        'Structure',
        'Symbol',
        'Word',
        'operator !',
        'operator + (binary)',
        'operator + (unary)',
        'operator ,',
        'operator - (binary)',
        'operator - (unary)',
        'operator ->',
        'operator -e',
        'operator :',
        'operator <=>',
        'operator =',
        'operator =>',
        'operator =~',
        'operator ?',
        'word elsif',
        'word if',
        'word my',
        'word print',
        'word return',
      ],
      'an operator and a keyword show their text, a sign shows its arity, and a name used as data is a plain word';
};

subtest 'the census rejects a key that no token-level mutant covers' => sub {
    my $census = census_of("sub f { return \$_[0] + \$_[1] <=> 2 }\nsub g { my \$n = 1 + 2; return }\n1;\n");
    is $census->{observed}{'operator + (binary)'}, 2,     'both additions are observed';
    is $census->{claimed}{'operator + (binary)'},  2,     'and a mutator changes each';
    is $census->{observed}{'operator <=>'},        1,     'the comparison of three ways is observed';
    is $census->{claimed}{'operator <=>'},         undef, 'and no mutator changes it';
    is $census->{claimed}{'Symbol'},               undef, 'a return value that is one variable changes no variable';
    is $census->{claimed}{'Structure'}, undef,
      'and the removal of a statement or of a body changes no token of its own';
    is $census->{claimed}{'Number'}, 6, 'a number is claimed, in a subscript and as the final value of the file too';
};

subtest 'the gate rejects an undecided key, a declined key with a mutant, and a declined key that never shows' => sub {
    my %census = (
        observed => { 'operator +' => 3, 'operator <=>' => 1, 'operator ,' => 9, 'operator =>' => 2 },
        claimed  => { 'operator +' => 3, 'operator =>'  => 1 },
    );
    my %declined = ( 'operator ,' => 'a separator', 'operator =>' => 'a separator', 'operator ~~' => 'gone from perl' );
    is Census::undecided( \%census, \%declined ),
      [
        'a mutant covers operator =>, and a reason declines it',
        'a reason declines operator ~~, and the corpus never shows it',
        'no mutant covers operator <=>, and no reason declines it',
      ],
      'one finding for each kind of gap';
    is Census::undecided( { observed => { 'operator +' => 1 }, claimed => { 'operator +' => 1 } }, {} ), [],
      'a census without a gap';
};

subtest 'a statement that no mutant touches counts for its class' => sub {
    my $census = census_of("use constant LIMIT => 1 + 2;\nmy \$n = 3;\nmy \@list;\nsub f { return LIMIT + 1 }\n1;\n");
    is $census->{statements},
      {
        'Statement'           => { all => 1, bare => 0 },
        'Statement::Break'    => { all => 1, bare => 0 },
        'Statement::Include'  => { all => 1, bare => 1 },
        'Statement::Variable' => { all => 2, bare => 1 },
      },
      'the statements by class, and the ones that hold no mutant';
    is Census::bare_classes($census), ['Statement::Include'], 'a class whose statements all go without a mutant';
};

my $SEED = <<'CODE';
my ( $x, @list ) = ( \&code, [ 1, 2 ] );
print { $x->[0] } "@list$#list";
LABEL: for my $item ( @{ $x }, $_ ) { next LABEL }
sub with($) { return }
sub attributed :lvalue { $x }
__END__
CODE

my @files   = map { Library::modules($_)->@* } 't/corpus', 't/fixtures', 'lib';
my $workers = min( 8, Test::Mutation::Project::cpu_count() );
my $records =
  Oracle::each_file( \@files, $workers, sub ($path) { return Census::records( Oracle::file_source($path) ) } );
push $records->@*, map { [ 'seed', $_->@* ] } Census::records( Oracle::text_source( 'seed', $SEED ) );
my $census = Census::summary($records);

note sprintf '%-28s %8s %8s', 'key', 'observed', 'claimed';
note sprintf '%-28s %8d %8d', $_, $census->{observed}{$_}, $census->{claimed}{$_} || 0
  for sort keys $census->{observed}->%*;
note sprintf '%-28s %6d statements, %6d without a mutant', $_, $census->{statements}{$_}->@{qw(all bare)}
  for sort keys $census->{statements}->%*;
note sprintf '%s: %d of %d statements without a mutant', $_->@* for Census::barest_files( $census, 10 );

is $census->{unplaced}, 0, 'PPI places every token of the corpus on its own text';
Gate::findings( 'mutants-census-corpus', Census::undecided( $census, Census::declined() ) );
Gate::findings( 'mutants-statements-corpus',
    [ map { "no mutant touches a statement of the class $_" } Census::bare_classes($census)->@* ] );
Gate::checked( 'files',      scalar @files,                                              at_least => 50 );
Gate::checked( 'keys',       scalar keys $census->{observed}->%*,                        at_least => 80 );
Gate::checked( 'tokens',     sum0( values $census->{observed}->%* ),                     at_least => 30_000 );
Gate::checked( 'statements', sum0( map { $_->{all} } values $census->{statements}->%* ), at_least => 4000 );

done_testing;
