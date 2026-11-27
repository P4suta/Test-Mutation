use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file run_bare);

# Experiment E10: does an END block run after a compile error in the main program?
# The shim writes its end record from an END block, so the answer decides what a process without that record means.

my $root = project();
write_file( "$root/lib/Ender.pm", <<'PERL' );
package Ender;
use strict;
use warnings;
END { syswrite STDOUT, "module-end status=$?\n" }
1;
PERL
write_file( "$root/lib/Broken.pm", "package Broken;\nsub value { 1 +* }\n1;\n" );

# The lines that the program and the END blocks wrote, then how the process ended.
sub ending {
    my ( $script, @switches ) = @_;
    write_file( "$root/script.pl", $script );
    my $run = run_bare( root => $root, args => [ '-Ilib', '-MEnder', @switches, 'script.pl' ] );
    return join q{ }, ( map { "$_;" } split /\n/, $run->{stdout} ), "exit=$run->{status}", "signal=$run->{signal}";
}

my $say_ran    = qq{syswrite STDOUT, "ran\\n";\n};
my $main_end   = qq{END { syswrite STDOUT, "main-end\\n" }\n};
my $error_line = "my \$broken = ;\n";

is ending( $say_ran . $error_line ), 'module-end status=255; exit=255 signal=0',
  'after a compile error in the main program the END block of a -M module runs and reads the status 255';
is ending( $main_end . $error_line ), 'main-end; module-end status=255; exit=255 signal=0',
  'an END block of the main program that stands before the error runs too';
is ending( $error_line . $main_end ), 'module-end status=255; exit=255 signal=0',
  'an END block that stands after the error never compiled and does not run';
is ending("use Broken;\n$say_ran"), 'module-end status=255; exit=255 signal=0',
  'after a compile error in a module that the main program uses the END block runs';
is ending("BEGIN { exit 4 }\n$say_ran"), 'module-end status=4; exit=4 signal=0',
  'after an exit during the compilation the END block runs and reads the status of the exit';

is ending( $say_ran,    '-c' ), 'exit=0 signal=0',   'under -c no END block runs after a program that compiles';
is ending( $error_line, '-c' ), 'exit=255 signal=0', 'under -c no END block runs after a compile error';

is ending($say_ran),    'ran; module-end status=0; exit=0 signal=0', 'a program that ends runs the END block';
is ending("exit 3;\n"), 'module-end status=3; exit=3 signal=0',      'an exit runs the END block with its status';
is ending("\$! = 0;\ndie qq{stop\\n};\n"), 'module-end status=255; exit=255 signal=0',
  'a die runs the END block with the status 255';

is ending("use POSIX ();\nPOSIX::_exit(5);\n"), 'exit=5 signal=0', 'POSIX::_exit runs no END block';
is ending("exec \$^X, '-e', 'syswrite STDOUT, qq{replaced\\n}';\n"), 'replaced; exit=0 signal=0',
  'a process that replaced its program runs no END block';
is ending("kill 'TERM', \$\$;\nsleep 5;\n"), 'exit=0 signal=15', 'a process that a signal ended runs no END block';

done_testing;
