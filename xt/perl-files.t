use v5.36;
use Test2::V0;
use Perl::Critic ();
use Perl::Tidy   ();
use lib 't/lib';
use Gate;
use Library;

# Every Perl file that Git tracks is formatted and passes the lint, or stands among the inputs of a test.
# The list comes from Git and from the first line of each file, so a new directory or a script without a suffix joins it.

sub untidy ($text) {
    my ( $formatted, $errors );
    my $failed = Perl::Tidy::perltidy(
        source      => \$text,
        destination => \$formatted,
        stderr      => \$errors,
        perltidyrc  => '.perltidyrc',
        argv        => [],
    );
    die "perltidy failed: $errors\n" if $failed;
    return $formatted ne $text ? 1 : 0;
}

my %PROFILE = ( library => '.perlcriticrc', program => 'xt/perlcriticrc' );
my %critic;

sub lint ( $kind, $source ) {
    $critic{$kind} ||= Perl::Critic->new( -profile => $PROFILE{$kind} );
    return [ map { sprintf '%s at line %d', $_->policy =~ s/\APerl::Critic::Policy:://r, $_->line_number }
          $critic{$kind}->critique($source) ];
}

subtest 'the gate rejects a Perl file that no check would read' => sub {
    my @cases = (
        [ 'lib/A/B.pm',                  "package A::B;\n",       'library' ],
        [ 'bin/tool',                    "#!/usr/bin/env perl\n", 'program' ],
        [ 'script/run',                  "#!perl -w\n",           'program' ],
        [ 'Makefile.PL',                 "use 5.036;\n",          'program' ],
        [ 'cpanfile',                    "requires 'perl';\n",    'program' ],
        [ 't/unit/a.t',                  "use v5.36;\n",          'program' ],
        [ 'xt/mutants/corpus.t',         "use v5.36;\n",          'program' ],
        [ 't/e2e/lib/Fixture.pm',        "package Fixture;\n",    'program' ],
        [ 't/corpus/modern/Class.pm',    "use v5.38;\n",          'input' ],
        [ 't/fixtures/calc/lib/Calc.pm', "package Calc;\n",       'input' ],
        [ 't/fixtures/calc/t/add.t',     "use Test::More;\n",     'input' ],
        [ 'README.md',                   "# Test-Mutation\n",     undef ],
        [ 'xt/schema/report.json',       "{\n",                   undef ],
        [ 'lib/A/resources/viewer.js',   "/* perl */\n",          undef ],
        [ 'bin/setup',                   "#!/bin/sh\n",           undef ],
        [ 'docs/adr/use-perl.md',        "---\n",                 undef ],
    );
    is Library::kind( $_->[0], $_->[1] ), $_->[2], $_->[0] for @cases;
};

subtest 'the gate rejects text that the formatter would change' => sub {
    is untidy("use v5.36;\nmy \$x = 1;\n"),             0, 'formatted text';
    is untidy("use v5.36;\nmy \$x=1;\n"),               1, 'a missing space';
    is untidy("use v5.36;\nif (\$x) {\n  say 1;\n}\n"), 1, 'a wrong indent';
};

subtest 'the gate rejects code that the lint refuses' => sub {
    is lint( 'library', \"package A;\nuse v5.36;\nour \$VERSION = '1';\nsub one () { return 1 }\n1;\n" ), [],
      'clean code';
    is lint( 'library', \"package A;\nuse v5.36;\nour \$VERSION = '1';\nsub one () { return eval 'q' }\n1;\n" ),
      ['BuiltinFunctions::ProhibitStringyEval at line 4'], 'a string evaluation in the library';
    is lint( 'program', \"use v5.36;\nmy \$value = eval '1';\n" ), ['BuiltinFunctions::ProhibitStringyEval at line 2'],
      'a string evaluation in a program';
    is lint( 'program', \"use v5.36;\nopen my \$in, '<', 'a' or die 'no file';\nclose \$in or die 'close';\n" ), [],
      'a program dies without Carp and has no package';
};

my $files = Library::perl_files();
my @found;
for my $kind (qw(library program)) {
    for my $file ( $files->{$kind}->@* ) {
        open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
        my $text = do { local $/ = undef; readline $handle };
        close $handle or die "close $file: $!";
        push @found, "$file is not formatted" if untidy($text);
        push @found, map { "$file: $_" } lint( $kind, $file )->@*;
    }
}
is \@found, [], 'every library file and every program is formatted and passes the lint';

my %program = map { $_ => 1 } $files->{program}->@*;
is [ grep { !$program{$_} } qw(bin/mutation Makefile.PL cpanfile xt/mutants/corpus.t xt/bin/perl-files) ], [],
  'the command, the build script, the requirements, and the corpus gate are among the programs';
is [ grep { !m{\At/(?:corpus|fixtures)/} } $files->{input}->@* ], [], 'the inputs are the corpus and the fixtures';
Gate::checked( 'library files', scalar $files->{library}->@*, at_least => 32 );
Gate::checked( 'programs',      scalar $files->{program}->@*, at_least => 80 );
Gate::checked( 'inputs',        scalar $files->{input}->@*,   at_least => 25 );

done_testing;
