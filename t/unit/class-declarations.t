use v5.36;
use Test2::V0;
use Test::Mutation::Syntax::PPI;

subtest 'classes can share a module with other declarations and load-time expressions' => sub {
    my $pragma = q{use experimental 'class'; sub read_limit { return $ENV{LIMIT} }};
    my $reads  = sub ($body) { return scalar Test::Mutation::Syntax::PPI::compile_reads( "$pragma $body", 1 ) };
    is $reads->(q{class First { method count { 1 } } class Second 1.0 { method count { 2 } } 1;}), [],
      'two classes with deferred methods can occupy one PPI statement';
    for my $body (
        q{class First {} class Second { my $limit = main::read_limit(); } 1;},
        q{class Meter {} read_limit; 1;},
        q{class Meter {} 0 + read_limit(); 1;},
        q{class Meter; main::read_limit(); 1;},
        q{sub Rules::apply { return main::read_limit() } apply Rules {}; 1;},
      )
    {
        is $reads->($body), undef, "loading the module can execute read_limit in $body";
    }
};

subtest 'native object initialization is deferred while a class body can run code at load' => sub {
    my $pragma = q{use experimental 'class';};
    my $reads  = sub ($source) { return scalar Test::Mutation::Syntax::PPI::compile_reads( "$pragma $source", 1 ) };
    is $reads->(
        q{class Model 1.0 { field $n :param = read_setting(); ADJUST { observe() } method get { return $n } } 1;}),
      [], 'loading declarations does not initialize a field, adjust an object, or call a method';
    is $reads->(q{class Model { method get { 1 } read_setting(); } 1;}), undef,
      'a call following a method runs as part of the class body';
    is $reads->(q{class Model { method get { 1 } } read_setting(); 1;}), undef,
      'a call following the class runs as part of the file';
    is $reads->(q{class Model { method get { 1 } }; open my $data, '<', $ENV{CLASS_FILE} or die $!; 1;}), undef,
      'loading the module opens the file named in a separate statement after the class';
    is $reads->(q{class Model { method get { 1 } BEGIN { read_setting() } } 1;}), undef,
      'a phase block after a method can read a file while compiling the class';
    is $reads->(q{class Model { method get { method inner { 1 } BEGIN { read_setting() } } } 1;}), undef,
      'a phase block inside a nested declaration runs before any method is called';
    is $reads->(q{class Model :isa(External) { method get { 1 } } 1;}), undef,
      'the base class can require an external module';
    is $reads->(q{class Model { method import { read_setting() } } 1;}), undef, 'an import method can run on use';
};

done_testing;
