use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use Gate;
use Judge;

# Perl is the judge of a mutant.
# A server compiles each unit in a child of its own, and the walker names every call that has no subroutine.

my $units = 0;

my $CALLS = <<'UNIT';
package Unit;
use strict;
use warnings;
use List::Util qw(max);
my $shared = 3;
sub named { return direct($shared) + List::Util::max( 1, 2 ) + max( 3, 4 ) + Other::qualified() }
my $anonymous = sub { return in_anonymous(@_) };
if ($shared) { in_branch(4) } else { for my $i ( 1 .. 3 ) { in_loop($i) } }
my sub lexical { in_lexical() }
my @list = map { in_map($_) } 1 .. 3;
$shared->a_method;
my $reference = \&a_reference;
BEGIN { *aliased = sub { in_begin() } }
aliased(1);
later(2);
sub later { return sub { sub { in_nested() } } }
1;
__END__
text after the end (
UNIT
my @CALLED = qw(
  Other::qualified Unit::direct Unit::in_anonymous Unit::in_begin Unit::in_branch Unit::in_lexical Unit::in_loop
  Unit::in_map Unit::in_nested
);

sub judged ( $judge, $code, @wants ) {
    $units++;
    return Judge::compiled( $judge, $code, @wants );
}

subtest 'the walker names every call without a subroutine' => sub {
    my $cold = Judge::reference_calls($CALLS);
    is $cold->{compiled}, 1,        'the unit compiles as a program';
    is $cold->{calls},    \@CALLED, 'calls of the file, of a named, an anonymous, a lexical, and a nested subroutine';

    my $judge = Judge::start();
    my $warm  = judged( $judge, $CALLS, 'calls', 'loaded' );
    is $warm->{compiled}, 1,        'the unit compiles in a child of the server';
    is $warm->{calls},    \@CALLED, 'the child names the same calls';
    ok scalar( grep { $_ eq 'List/Util.pm' } $warm->{loaded}->@* ), 'the child names the files it loaded';

    Judge::preload( $judge, $warm->{loaded}->@* );
    is judged( $judge, $CALLS, 'calls' )->{calls}, \@CALLED, 'modules that the server holds change no answer';
    Judge::stop($judge);
};

subtest 'the judge rejects a swap to a name that the unit never imports' => sub {
    my $judge = Judge::start();
    my $unit  = "use strict;\nuse List::Util qw(max);\nsub largest { return max(\@_) }\n1;\n";
    is judged( $judge, $unit, 'calls' )->{calls}, [], 'the imported name resolves';
    is judged( $judge, $unit =~ s/max[(]/min(/r, 'calls' ),
      hash { field compiled => 1; field calls => ['main::min']; etc },
      'the swapped name compiles and resolves to nothing';
    is judged( $judge, $unit =~ s/max[(]\@_[)]/min \@_/r ), hash { field compiled => 0; etc },
      'the swapped name without parentheses fails to compile';

    is judged( $judge, "sub helper { return 1 }\n1;\n", 'calls' )->{calls}, [], 'a unit that defines a helper';
    is judged( $judge, "sub other { return helper() }\n1;\n", 'calls' )->{calls}, ['main::helper'],
      'the next unit starts without the subroutines of the last one';
    Judge::stop($judge);
};

subtest 'the judge rejects a unit that perl refuses' => sub {

    # A unit that must end gets the usual limit, so a busy machine turns no sound unit into one that never ends.
    my $judge = Judge::start();
    my $brief = Judge::start( timeout => 1 );
    is judged( $judge, "sub f { return 1 }\n1;\n" ), hash { field compiled => 1; field diagnostics => q{}; etc },
      'a sound unit';
    my $brace = judged( $judge, "sub f { return 1 }\n}\n1;\n" );
    is $brace->{compiled}, 0, 'a closing brace too many';
    like $brace->{diagnostics}, qr/\AUnmatched right curly bracket at - line 2/, 'the diagnostics name the line';
    my $death = judged( $judge, "BEGIN { die qq{no\\n} }\n1;\n" );
    is $death->{compiled}, 0, 'a death during compilation';
    like $death->{diagnostics}, qr/\Ano\nBEGIN failed--compilation aborted at - line 1/,
      'the diagnostics name the block';
    is judged( $judge, "BEGIN { exit 0 }\n}\n" )->{compiled}, 0, 'an exit during compilation hides no error';
    is judged( $judge, "use strict;\nsub f { return \$missing }\n1;\n", 'calls' )->{compiled}, 0,
      'an undeclared variable, with the walker at work';
    is judged( $brief, "BEGIN { 1 while 1 }\n1;\n" ), hash { field compiled => 0; field timed_out => 1; etc },
      'a unit that never ends';
    is Judge::stop($brief), 1, 'the server outlives the unit it stopped and ends cleanly';
    is judged( $judge, "print STDERR qq{noise\\n};\n1;\n" )->{compiled}, 1, 'a unit that prints while perl compiles it';
    Judge::stop($judge);
};

subtest 'the judge rejects a unit whose modules stand outside the search path' => sub {
    my $unit    = "use Calc;\n1;\n";
    my @library = ( include => ['t/fixtures/calc/lib'] );
    my $without = Judge::start();
    is judged( $without, $unit )->{compiled}, 0, 'the module is out of reach';
    is Judge::stop($without),                 1, 'the server ends cleanly';
    my $with = Judge::start(@library);
    is judged( $with, $unit )->{compiled},  1, 'a directory of the search path reaches it';
    is Judge::reference( $unit, @library ), 1, 'perl -c agrees';
    is Judge::reference($unit),             0, 'and it agrees without the directory';
    Judge::stop($with);
};

subtest 'the compiled code rejects a change that only the layout shows' => sub {
    my $judge = Judge::start();
    my $text  = sub ($code) { return judged( $judge, $code, 'deparse' )->{deparse} };
    my $base  = $text->("sub f { return \$_[0] + 1 }\n1;\n");
    ok length $base, 'the child prints the compiled code';
    is $text->("sub f {\n    return \$_[0] + 1;    # a comment\n}\n1;\n"), $base, 'layout and comments change nothing';
    isnt $text->("sub f { return \$_[0] - 1 }\n1;\n"),                     $base, 'another operator shows';
    is $text->("sub f { return \$_[0] + 1 }\n1;\n"),                       $base, 'the same code prints the same text';

    # B::Deparse of some interpreters dies on this loop, and the verdict then names the reason in place of the code.
    my $loop = judged( $judge, "sub f { my \@out; for my \$line (\@_) { if (0) { next } push \@out, \$line } }\n1;\n",
        'deparse' );
    is $loop->{compiled}, 1, 'a unit that B::Deparse may fail to print compiles all the same';
    is defined $loop->{deparse} ? 'printed' : 'failed', length $loop->{undeparsed} ? 'failed' : 'printed',
      'and its verdict holds either the code or the reason of the failure';
    Judge::stop($judge);
};

subtest 'the server rejects no request after a module that reads, prints, or hangs while it loads' => sub {
    my $directory = File::Temp->newdir;
    my %module    = (
        Noisy => "package Noisy;\nmy \$line = <STDIN>;\nprint qq{done\\n};\n1;\n",
        Hangs => "package Hangs;\n1 while 1;\n1;\n",
    );
    for my $name ( sort keys %module ) {
        open my $handle, '>', "$directory/$name.pm" or die "write $name: $!";
        print {$handle} $module{$name} or die "write $name: $!";
        close $handle                  or die "close $name: $!";
    }
    my $judge = Judge::start( include => ["$directory"] );
    is Judge::preload( $judge, 'Noisy.pm' ), 1, 'the server loads a module that reads the standard input and prints';
    is judged( $judge, "use Noisy;\nsub f { return missing() }\n1;\n", 'calls' )->{calls}, ['main::missing'],
      'and the next request gets its own answer';
    is Judge::stop($judge), 1, 'the server ends cleanly';

    my $stuck = Judge::start( include => ["$directory"], patience => 1 );
    like dies { Judge::preload( $stuck, 'Hangs.pm' ) }, qr/\Athe judge gives no answer/,
      'a module that never ends its loading costs the patience of the caller';
    is Judge::stop($stuck), 0, 'and the caller ends the server that hangs';
};

subtest 'the judge rejects a unit that fails to load' => sub {
    my $judge  = Judge::start();
    my $brief  = Judge::start( timeout => 1 );
    my $loaded = sub ($code) { $units++; return Judge::loaded( $judge, $code ) };
    is $loaded->("package Loads;\nsub f { return 1 }\n1;\n"), hash { field loaded => 1; field diagnostics => q{}; etc },
      'a unit with a true value loads';
    my $false = $loaded->("package Loads;\nsub f { return 1 }\n0;\n");
    is $false->{loaded}, 0, 'a unit with a false value fails';
    like $false->{diagnostics}, qr/did not return a true value/, 'and perl names the missing value';
    my $death = $loaded->("package Loads;\ndie qq{no start\\n};\n1;\n");
    is $death->{loaded}, 0, 'a unit that dies while it loads fails';
    like $death->{diagnostics}, qr/\Ano start\n/, 'and the diagnostics start with its message';
    is Judge::loaded( $brief, "package Loads;\n1 while 1;\n1;\n" ),
      hash { field loaded => 0; field timed_out => 1; etc },
      'a unit that never ends its loading is stopped';
    Judge::stop($brief);
    is $loaded->("package Loads;\nour \$ran = 1;\nexit 0;\n")->{loaded}, 0, 'an exit while it loads is no success';
    is $loaded->("package Loads;\nsub f { return missing() }\n1;\n")->{loaded}, 1,
      'a call without a subroutine loads until some code runs it';
    Judge::stop($judge);
};

Gate::checked( 'units', $units, at_least => 20 );

done_testing;
