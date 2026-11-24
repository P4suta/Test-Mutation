use strict;
use warnings;
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(project write_file run_bare);

# Experiments E1 to E4: a source filter that the import of a -M module adds, over the main program.
# The answers decide whether a script that runs as a program can get a line trace and a mutant without a new file.

my $root = project();
write_file( "$root/lib/MainFilter.pm", <<'PERL' );
package MainFilter;
use strict;
use warnings;
use Filter::Util::Call;

sub lines_of {
    my ($path) = @_;
    return [] if !defined $path;
    open my $in, '<', $path or die "read $path: $!";
    my @lines = <$in>;
    close $in or die "close $path: $!";
    return \@lines;
}

sub note_line {
    my ( $label, $text ) = @_;
    return if !defined $ENV{MAIN_FILTER_LOG};
    $text =~ s/\n/\\n/g;

    # The path comes from the environment, and taint mode refuses to write to such a path as it stands.
    my ($log) = $ENV{MAIN_FILTER_LOG} =~ /\A(.*)\z/s;
    open my $out, '>>', $log or die "log: $!";
    print {$out} "$label\t$text\n";
    close $out or die "close the log: $!";
    return;
}

sub import {
    my $mode        = defined $ENV{MAIN_FILTER} ? $ENV{MAIN_FILTER} : 'pass';
    my $replacement = lines_of( $ENV{MAIN_FILTER_TEXT} );
    my ( $index, $given ) = ( 0, 0 );
    note_line( 'program', $0 );
    my %read = (

        # Every line goes on as it came.
        pass => sub {
            my $status = filter_read();
            note_line( $index++, $_ ) if $status > 0;
            return $status;
        },

        # Line N of the replacement stands in for line N of the file.
        lines => sub {
            my $status = filter_read();
            return $status if $status <= 0;
            note_line( $index, $_ );
            $_ = $replacement->[$index] if defined $replacement->[$index];
            $index++;
            return $status;
        },

        # The filter reads the file to its end and hands over the whole replacement at once.
        whole => sub {
            return 0 if $given++;
            1 while filter_read() > 0;
            note_line( 'all', $_ );
            $_ = join q{}, @{$replacement};
            return 1;
        },

        # The filter reads blocks of bytes where the others read lines.
        block => sub {
            my $status = filter_read(8192);
            note_line( 'block', $_ ) if $status > 0;
            return $status;
        },
    );
    my $reader = $read{$mode} or die "no mode is named $mode";
    filter_add(
        sub {
            my $status = $reader->();
            note_line( 'end', $status ) if $status <= 0;
            return $status;
        }
    );
    return;
}

1;
PERL

sub slurp {
    my ($path) = @_;
    open my $in, '<', $path or return q{};
    local $/ = undef;
    my $text = <$in>;
    close $in or die "close $path: $!";
    return defined $text ? $text : q{};
}

# A run of a program under the filter, with the lines that the filter received.
sub filtered {
    my (%run) = @_;
    unlink "$root/filter.log";
    my %env    = ( MAIN_FILTER_LOG => "$root/filter.log", %{ $run{env} || {} } );
    my @module = $run{through} eq 'switch' ? ( '-Ilib', '-MMainFilter' ) : ();
    %env = ( %env, PERL5OPT => '-MMainFilter', PERL5LIB => "$root/lib" ) if $run{through} eq 'environment';
    my $got = run_bare( root => $root, env => \%env, args => [ @{ $run{before} || [] }, @module, @{ $run{args} } ] );
    my @log = split /\n/, slurp("$root/filter.log");
    $got->{program} = join q{,}, map { /\Aprogram\t(.*)\z/ ? $1 : () } @log;
    $got->{log}     = [ grep { !/\Aprogram\t/ } @log ];
    return $got;
}

sub logged {
    my (@lines) = @_;
    s/\n/\\n/g for @lines;
    return [ map { "$_\t$lines[$_]" } 0 .. $#lines ];
}

# E1: every line of the main program passes the filter, and the program reads its own name and lines unchanged.
my @program = (
    "#!/usr/bin/perl\n",
    "use strict;\n",
    "use warnings;\n",
    "sub where { return join q{:}, ( caller 0 )[ 1, 2 ] }\n",
    "print \"zero=\$0 file=\", __FILE__, ' line=', __LINE__, ' caller=', where(), \"\\n\";\n",
    "warn 'warned';\n",
    "print 'last line'",
);
write_file( "$root/script.pl", join q{}, @program );
my $plain = run_bare( root => $root, args => ['script.pl'] );
is $plain->{stdout}, "zero=script.pl file=script.pl line=5 caller=script.pl:5\nlast line",
  'E1: the program names itself and its lines';
is $plain->{stderr}, "warned at script.pl line 6.\n", 'E1: and its warning names its line';

for my $through (qw(switch environment)) {
    my $run = filtered( through => $through, args => ['script.pl'] );
    is $run->{status}, 0,                'E1: exit status' or diag $run->{stderr};
    is $run->{stdout}, $plain->{stdout}, "E1: the name, the file, and the lines stay under a filter from the $through";
    is $run->{stderr}, $plain->{stderr}, "E1: the warning names the same line under a filter from the $through";
    is_deeply $run->{log}, [ @{ logged(@program) }, "end\t0" ],
      "E1: the filter from the $through receives every line of the main program, and no line of a module"
      or diag join "\n", @{ $run->{log} };
    is $run->{program}, 'script.pl', "E1: the import from the $through reads the name of the main program in \$0";
}

# A program of the command line has no file, and the filter receives its text all the same.
my $inline = filtered( through => 'environment', args => [ '-e', 'print "zero=$0\n"' ] );
is $inline->{stdout},  "zero=-e\n", 'E1: a program of the -e switch runs under the filter';
is $inline->{program}, '-e',        'E1: and the import reads -e as its name';
is_deeply $inline->{log}, [ "0\tprint \"zero=\$0\\n\"\\n", "end\t0" ], 'E1: the filter receives the text of the switch'
  or diag join "\n", @{ $inline->{log} };

# E2: the switches of the first line take effect on the text that the filter hands over.
write_file( "$root/warns.pl", "#!perl -w\nprint \"w=\$^W\\n\";\n" );
write_file( "$root/quiet.pl", "#!perl\nprint \"w=\$^W\\n\";\n" );
is run_bare( root => $root, args => ['warns.pl'] )->{stdout}, "w=1\n", 'E2: -w of the first line turns the warnings on';
is filtered( through => 'switch', args => ['warns.pl'] )->{stdout}, "w=1\n", 'E2: and it does so under the filter';
is filtered( through => 'switch', args => ['quiet.pl'] )->{stdout}, "w=0\n",
  'E2: a first line without it leaves them off';
is filtered(
    through => 'switch',
    args    => ['quiet.pl'],
    env     => { MAIN_FILTER => 'lines', MAIN_FILTER_TEXT => 'warns.pl' }
)->{stdout}, "w=1\n", 'E2: the interpreter reads the switches from the first line that the filter hands over';

write_file( "$root/taint.pl", "#!perl -T\nprint \"taint=\${^TAINT}\\n\";\n" );
my $late = qr/\A"-T" is on the #! line, it must also be used on the command line at taint[.]pl line 1[.]\n\z/;
my $bare = run_bare( root => $root, args => ['taint.pl'] );
like $bare->{stderr}, $late, 'E2: -T of the first line without -T of the command line stops the program';
my $refused = filtered( through => 'switch', args => ['taint.pl'] );
like $refused->{stderr}, $late, 'E2: and it stops the program under the filter';
isnt $refused->{status}, 0,   'E2: with a failing exit status';
is $refused->{stdout},   q{}, 'E2: before the program prints';
my $tainted = filtered( through => 'switch', before => ['-T'], args => ['taint.pl'] );
is $tainted->{stdout}, "taint=1\n", 'E2: with -T on the command line the program runs in taint mode under the filter'
  or diag $tainted->{stderr};
is_deeply $tainted->{log}, [ "0\t#!perl -T\\n", "1\tprint \"taint=\${^TAINT}\\n\";\\n", "end\t0" ],
  'E2: and the filter receives its lines';

# E3: the DATA handle reads the file itself, from the place where the interpreter stopped to read.
my $reader = <<'PERL';
#!/usr/bin/perl
use strict;
use warnings;
sub value { return 41 }
my $data = join q{}, <DATA>;
$data =~ tr/\n/|/;
seek DATA, 0, 0;
my @all = <DATA>;
my ($number) = join( q{}, @all ) =~ /return (\d+)/;
print 'value=', value(), " data=$data all=", scalar @all, " reread=$number\n";
MARKER
alpha
beta
PERL

for my $marker (qw(__END__ __DATA__)) {
    ( my $original = $reader )   =~ s/MARKER/$marker/;
    ( my $mutant   = $original ) =~ s/return 41/return 42/;
    my @file  = split /(?<=\n)/, $original;
    my $lines = @file;
    my @code  = @file[ 0 .. $lines - 3 ];
    write_file( "$root/data.pl",   $original );
    write_file( "$root/mutant.pl", $mutant );

    is run_bare( root => $root, args => ['data.pl'] )->{stdout}, "value=41 data=alpha|beta| all=$lines reread=41\n",
      "E3 $marker: the program reads its data and rereads its own text";

    my $pass = filtered( through => 'switch', args => ['data.pl'] );
    is $pass->{stdout}, "value=41 data=alpha|beta| all=$lines reread=41\n",
      "E3 $marker: under a filter that passes the lines on, DATA and the seek work";
    is_deeply $pass->{log}, logged(@code), "E3 $marker: the filter receives the lines up to the marker and no more"
      or diag join "\n", @{ $pass->{log} };

    my %text = ( MAIN_FILTER_TEXT => 'mutant.pl' );
    is filtered( through => 'switch', args => ['data.pl'], env => { MAIN_FILTER => 'lines', %text } )->{stdout},
      "value=42 data=alpha|beta| all=$lines reread=41\n",
      "E3 $marker: a replacement line for line runs, DATA reads the data, and the seek rereads the text of the file";

    is filtered( through => 'switch', args => ['data.pl'], env => { MAIN_FILTER => 'whole', %text } )->{stdout},
      "value=42 data= all=$lines reread=41\n",
      "E3 $marker: a replacement of the whole text runs, and DATA stands at the end of the file";

    is filtered( through => 'switch', args => ['data.pl'], env => { MAIN_FILTER => 'block' } )->{stdout},
      "value=41 data= all=$lines reread=41\n",
      "E3 $marker: a filter that reads blocks leaves DATA at the end of the block";
}

# E4: under -x the interpreter drops the leading text itself, and the filter starts at the line of the program.
my $wrapped = <<'TEXT';
leading text
more of it
#!perl -w
print "zero=$0 file=", __FILE__, ' line=', __LINE__, " w=$^W\n";
__END__
trailing text
TEXT
my @wrapped = split /(?<=\n)/, $wrapped;
write_file( "$root/wrapped.txt", $wrapped );

# The count starts at the first line of the program, and some releases count one line more.
# Perl 5.18.4 and earlier and 5.24.4 and later gave 2, and Perl 5.20.3, 5.22.4, and 5.24.1 gave 3.
# No release between those was at hand, so either answer passes there.
my $numbered =
    $] <= 5.018004 || $] >= 5.024004 ? '2'
  : $] >= 5.020003 && $] <= 5.024001 ? '3'
  :                                    '[23]';
my $extracted = run_bare( root => $root, args => [ '-x', 'wrapped.txt' ] );
like $extracted->{stdout}, qr/\Azero=wrapped[.]txt file=wrapped[.]txt line=$numbered w=1\n\z/,
  "E4: under -x the line after the first line of the program is line $numbered, which is 3 from Perl 5.20.3 to 5.24.1";
my $under = filtered( through => 'switch', before => ['-x'], args => ['wrapped.txt'] );
is $under->{stdout},  $extracted->{stdout}, 'E4: the filter leaves the name, the lines, and the switches as they were';
is $under->{program}, 'wrapped.txt',        'E4: the import reads the name of the file in $0';
is_deeply $under->{log}, logged( "\n", $wrapped[3], "__END__\n" ),
  'E4: the filter receives an empty line for the first line of the program, then the lines after it'
  or diag join "\n", @{ $under->{log} };

done_testing;
