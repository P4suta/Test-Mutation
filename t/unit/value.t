use v5.36;
use Test2::V0;
use Test::Mutation::Exit;
use Test::Mutation::Mutant::Validity;
use Test::Mutation::Mutator;

# A value of the library refuses an argument that names none of its attributes, so a misspelt name fails at once.

sub refusal ($code) {
    my $lived = eval { $code->(); 1 };
    return $lived ? 'no refusal' : "$@";
}

my %exit = ( code => 0, name => 'success', signal => undef, meaning => 'the run succeeded' );

is refusal( sub { Test::Mutation::Exit->new(%exit) } ), 'no refusal', 'the arguments of the attributes';
is refusal( sub { Test::Mutation::Exit->new( %exit, colour => 'red' ) } ),
  "the class Test::Mutation::Exit takes no argument colour\n", 'an argument that names no attribute';
is refusal( sub { Test::Mutation::Exit->new( %exit, zone => 1, colour => 'red' ) } ),
  "the class Test::Mutation::Exit takes no argument colour, zone\n", 'every such argument, in the order of the names';

my %mutator = ( name => 'arithmetic', profile => 'default', description => 'a change' );
is refusal(
    sub {
        Test::Mutation::Mutator->new( %mutator, generate => sub { [] } );
    }
  ),
  'no refusal',
  'an attribute that takes its value under another name';
is refusal(
    sub {
        Test::Mutation::Mutator->new( %mutator, generate => sub { [] }, _generate => sub { [] } );
    }
  ),
  "the class Test::Mutation::Mutator takes no argument _generate\n", 'and the name of the attribute itself';

my %validity = ( text => q{}, heredocs => [], names => { imports => [], declared => [] } );
is refusal( sub { Test::Mutation::Mutant::Validity->new(%validity) } ), 'no refusal', 'a class with a private state';
is refusal( sub { Test::Mutation::Mutant::Validity->new( %validity, _wide => \q{} ) } ),
  "the class Test::Mutation::Mutant::Validity takes no argument _wide\n", 'which no argument sets';

my @classes = map { "Test::Mutation::$_" }
  qw(Clock Command Config Coverage Error Exit Interrupted Message Mutant Mutant::Validity Mutator Result Setting Site Source Status);
for my $class (@classes) {
    my $file = ( $class =~ s{::}{/}gr ) . '.pm';
    require $file;
    ok $class->DOES('Test::Mutation::Value'), "$class composes the role";
}

done_testing;
