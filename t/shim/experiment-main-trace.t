use strict;
use warnings;
use Test::More;
use Config;
use lib 't/shim/lib';
use ShimHarness qw(project write_file run_bare);

# Experiment E5: the debugger flags that the import of a -M module sets, over the main program.
# The answers decide whether a script that runs as a program gets a line trace or a trace of the whole file.

my $root = project();
write_file( "$root/lib/MainTrace.pm", <<'PERL' );
package MainTrace;
use strict;
use warnings;
use Filter::Util::Call ();

my %hit;

sub import {
    my %with = map { $_ => 1 } split /,/, defined $ENV{MAIN_TRACE} ? $ENV{MAIN_TRACE} : q{};
    {

        package DB;
        no strict 'refs';
        *{'DB::DB'} = sub {
            my ( undef, $file, $line ) = caller;
            $hit{$file}{$line} = 1;
            return;
        };
    }
    if ( $with{array} ) {

        # The array of the source lines exists before the interpreter reads the first line.
        no strict 'refs';
        my $lines = \@{"main::_<$0"};
    }

    # The flags of the shim: a trace point for every statement, and no optimization that drops one.
    $^P = 0x02 | 0x04;
    $DB::trace = 1;
    return if !$with{switching};

    # A hook turns the flags off for every file that the program loads, as the shim does.
    # A filter turns them on again with every line of the main program, and off at its end.
    unshift @INC, sub { $^P = 0; return };
    Filter::Util::Call::filter_add(
        sub {
            my $status = Filter::Util::Call::filter_read();
            $^P = $status > 0 && !/\A__(?:END|DATA)__\s*\z/ ? 0x02 | 0x04 : 0;
            return $status;
        }
    );
    return;
}

END {
    $^P = 0;
    no strict 'refs';
    no warnings 'numeric';
    my $lines     = \@{"main::_<$0"};
    my @breakable = grep { defined $lines->[$_] && int( $lines->[$_] ) != int "$lines->[$_]" } 1 .. $#{$lines};
    my %files     = map  { m{([^/]+)\z} ? ( $1 => 1 ) : () } keys %hit;
    syswrite STDOUT, join q{}, map { "$_\n" } 'saved=' . scalar @{$lines}, "breakable=@breakable",
      'hits=' . join( q{ }, sort { $a <=> $b } keys %{ $hit{$0} || {} } ), 'files=' . join q{ }, sort keys %files;
}

1;
PERL
write_file( "$root/lib/Helper.pm", "package Helper;\nsub double { return \$_[0] * 2 }\n1;\n" );
write_file( "$root/script.pl",     <<'PERL' );
#!/usr/bin/perl
use Helper;
my $count = 0;

sub twice {
    my ($n) = @_;
    return Helper::double($n);
}

sub unused {
    return 0;
}
$count = twice(4);
print "count=$count\n";
__END__
print "never compiled\n";
PERL

sub traced {
    my ($with) = @_;
    my $run =
      run_bare( root => $root, env => { MAIN_TRACE => $with }, args => [ '-Ilib', '-MMainTrace', 'script.pl' ] );
    diag $run->{stderr} if length $run->{stderr};
    return { map { /\A(\w+)=(.*)\z/ ? ( $1 => $2 ) : ( output => $_ ) } split /\n/, $run->{stdout} };
}

# Line 2 loads a module, lines 3 to 14 hold the statements, line 11 never runs, and line 15 ends the program text.
my $executed = '2 3 6 7 13 14';
my $kept     = 16;

# From Perl 5.36 on, the line of a use loses its mark as a statement once the use has run.
# From Perl 5.36 on, the interpreter also keeps the lines of the main program for flags that an import sets.
# Before Perl 5.36 an interpreter with threads kept them, and one without threads kept none.
my $clears = $] >= 5.036                     ? 1                : 0;
my $keeps  = $clears || $Config{useithreads} ? 1                : 0;
my $marked = $clears                         ? '3 6 7 11 13 14' : '2 3 6 7 11 13 14';
my $since  = $clears ? 'from 5.36' : $keeps ? 'before 5.36 with threads' : 'before 5.36 without threads';

my $flags = traced(q{});
is $flags->{output}, undef,   'the program runs under the flags' or diag $flags->{output};
is $flags->{count},  8,       'and computes its value';
is $flags->{hits}, $executed, 'E5: flags from the import record a hit for every statement of the main program that ran';
is $flags->{files},     'Helper.pm script.pl', 'E5: the flags stay on for a module that the program loads';
is $flags->{saved},     $keeps ? $kept   : 0,   "E5 $since: the lines of the main program that the interpreter keeps";
is $flags->{breakable}, $keeps ? $marked : q{}, "E5 $since: the lines that the interpreter marks as statements";

my $array = traced('array');
is $array->{hits},      $executed, 'E5: an import that creates the array of the lines first records the same hits';
is $array->{saved},     $kept,     'E5: and the interpreter keeps the lines on every version';
is $array->{breakable}, $marked,   "E5 $since: the marked lines, where the line of a use keeps its mark before 5.36";

my $switching = traced('switching');
is $switching->{count},     8,           'the program runs under the hook and the filter';
is $switching->{hits},      $executed,   'E5: flags that a filter turns on with every line record the same hits';
is $switching->{files},     'script.pl', 'E5: and a hook that turns them off keeps the loaded module out of the trace';
is $switching->{breakable}, $keeps ? $marked : q{}, "E5 $since: the marked lines under the hook and the filter";

my $both = traced('array,switching');
is $both->{hits},  $executed,   'E5: the array, the hook, and the filter together record the same hits';
is $both->{files}, 'script.pl', 'E5: for the main program alone';
is $both->{saved}, $kept - 1, 'E5: with the kept lines on every version, up to the end marker that turns the flags off';
is $both->{breakable}, $marked, "E5 $since: and with the marked lines";

done_testing;
