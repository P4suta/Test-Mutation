use v5.36;
use Test2::V0;
use Test::Mutation::Syntax::PPI;

sub reads ($source) {
    return scalar Test::Mutation::Syntax::PPI::compile_reads($source);
}

my $quoted = q{"value ${ \do { BEGIN { main::observe() } 42 } }"};
my $regex  = q{qr/(?{ BEGIN { main::observe() } 1 })/};
is reads("sub description { return $quoted }"), undef, 'a phase inside string interpolation runs during compilation';
is reads("sub matches { return $regex }"),      undef, 'a regex code assertion compiles before a subroutine runs';
is reads(q{sub replace { s/BEGIN/ do { BEGIN { main::observe() } 42 } /e }}), undef,
  'a substitution compiles its Perl replacement';
is reads(q{sub uses { return "@{[ do { use Settings; 42 } ]}" }}), undef,
  'an import inside interpolation runs at compile time';
is reads(<<'SOURCE'), undef, 'an interpolating here-document can compile a phase block';
sub note { return <<TEXT;
${\do { BEGIN { main::observe() } 42 }}
TEXT
}
SOURCE
is reads(q{sub text { return q{BEGIN { main::observe() }}, qr/BEGIN\s+\w+/, "BEGIN $name" }}), [],
  'literal phase names in strings and regexes do not run';
is reads(q{sub text { return "value ${ \do { 'BEGIN' } }" }}), [],
  'a string literal inside an interpolated expression remains text';
is reads(q{sub nested { return "@{[ qr/(?{ CHECK { main::observe() } 1 })/ ]}" }}), undef,
  'embedded Perl can compile another regex with a phase block';
my $class = "use experimental 'class'; class Model { method describe { return $quoted } } 1;";
is scalar Test::Mutation::Syntax::PPI::compile_reads( $class, 1 ), undef,
  'a native method can compile an interpolated phase before object construction';

done_testing;
