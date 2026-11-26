package Samples;
use v5.36;
use Test::Mutation::Mutant;
use Test::Mutation::Result;
use Test::Mutation::Status;

# The sample values of every type of a setting, in one place, by the name of the type.
# A type that the configuration checks has samples outside it, and a type that is plain text has none.
# The samples of numbers hold the infinite, the undefined, and the oversized number, which no surface may take.
my %TYPE = (
    Count => {
        number  => 1,
        valid   => [ 2, 16 ],
        invalid => [ 0, -1, '1.5', 'x', '0x10', 'inf', '99999999999999999999' ]
    },
    Positive   => { number => 1, valid => [ 2, '0.5' ], invalid => [ 0, -1, 'x', 'inf', 'nan', '1e400' ] },
    Percent    => { number => 1, valid => [ 50, 0, 100, '99.5' ], invalid => [ -1, '100.5', 'x', 'inf' ] },
    Coverage   => { valid => [ 'file', 'line' ], invalid => ['branch'] },
    Profile    => { valid => [ 'extended', 'default' ], invalid => ['nonesuch'] },
    Format     => { valid => [ 'json', 'terminal', 'html' ], invalid => ['pdf'] },
    Shard      => { valid => [ '2/3', '1/1' ], invalid => [ '0/3', '4/3', '2', 'a/b' ] },
    Boolean    => { valid => [ 1, 0 ], invalid => ['yes'] },
    Directory  => { valid => [ 'out', 'reports/here' ] },
    File       => { valid => ['ci.toml'] },
    Program    => { valid => ['/opt/perl/bin/perl'] },
    Path       => { valid => [ 'vendor',      'local' ] },
    Glob       => { valid => [ 'src/**/*.pm', 'lib/Calc.pm' ] },
    Switch     => { valid => [ '-Ilib',       '-Mblib' ] },
    Revision   => { valid => ['HEAD'] },
    Identifier => { valid => [ '0123456789ab', 'ba9876543210' ] },
    Mutator    => { valid => [ 'arithmetic', 'sub-body' ] },
);

sub incomplete_import () {
    return {
        'lib/Local/Pair.pm' => <<'PERL',
package Local::Pair;
use strict;
use warnings;

sub import {
    no strict 'refs';
    *{caller() . '::min'} = sub { $_[0] };
}

1;
PERL
        'lib/Small.pm' => <<'PERL',
package Small;
use strict;
use warnings;
use Local::Pair qw(min max);

sub lesser { return min(@_) }

1;
PERL
        't/small.t' => <<'PERL',
use strict;
use warnings;
use Test::More tests => 1;
use Small;

is Small::lesser(2, 3), 2, 'the first argument is smaller';
PERL
    };
}

sub type ($name) {
    my $type = $TYPE{$name} or die "no type is named $name\n";
    return { number => 0, invalid => [], $type->%*, name => $name };
}

sub types () {
    return [ sort keys %TYPE ];
}

# The first words that name no command, each with the name that stands nearest to it.
my %NEAREST = (
    hepl    => 'help',
    hl      => 'help',
    version => '--version',
    lst     => 'list',
    runn    => 'run',
    shwo    => 'show',
    exce    => 'exec',
    merg    => 'merge',
    mutator => 'mutators',
    lits    => 'list',
    List    => 'list',
);

sub words_without_command () {
    return {%NEAREST};
}

# One operand for each place of a command that takes operands.
my %OPERANDS = (
    run   => ['lib/Calc.pm'],
    list  => ['lib/Calc.pm'],
    help  => ['show'],
    show  => ['0123456789ab'],
    exec  => [ '0123456789ab', 'true' ],
    merge => ['part.json']
);

sub operands ( $command, $count ) {
    my @named = @{ $OPERANDS{$command} || [] };
    return [ map { defined $named[$_] ? $named[$_] : "surplus$_" } 0 .. $count - 1 ];
}

# A value as the text of a configuration file: a number of a type of numbers as a number, and everything else as a text.
# The decoder of the file reads a number that is too large or no number at all from the same words as the command line.
my $TOML_NUMBER = qr/\A(?:-?[0-9]+(?:[.][0-9]+)?(?:e[0-9]+)?|0x[0-9]+|inf|nan)\z/;

sub toml ( $type, $value ) {
    return $value ? 'true' : 'false' if $type->{name} eq 'Boolean' && $value =~ /\A[01]\z/;
    return $value                    if $type->{number}            && $value =~ $TOML_NUMBER;
    return q{"} . $value =~ s/(["\\])/\\$1/gr . q{"};
}

my $SAMPLE_PATH = 'lib/Sample.pm';
my $SAMPLE_TEST = 't/sample.t';

# The letters that a source may hold next to its code: none, letters of Latin-1, and letters beyond it.
my %LETTERS = ( ascii => q{}, latin1 => "    # caf\x{e9}", utf8 => "    # \x{65e5}\x{672c}" );

sub letters () {
    return [ sort keys %LETTERS ];
}

# The lines of the source that belong to one mutant: one line of code, and a second line when the change spans two.
sub _unit ( $number, $letters, $lines ) {
    my $code = "sub f$number { return \$_[0] + $number }$LETTERS{$letters}\n";
    return $lines > 1 ? ( $code, "# after $number\n" ) : ($code);
}

# The first reason that the catalog gives the status, and a sentence about the case.
sub _reason ($status) {
    return 'compile-phase' if $status eq 'CompileError';
    return Test::Mutation::Status::of($status)->reasons->[0];
}

sub _detail ($status) {
    return $status eq 'Killed' ? "$SAMPLE_TEST failed" : $status eq 'Survived' ? undef : "detail of $status";
}

# A result with one mutant for each status, in a source with the lines of each mutant in turn.
# `letters` names the letters of the source, and `lines` is the number of lines that each change spans.
sub result (%arg) {
    my @statuses = @{ delete $arg{statuses} || [] };
    my $letters  = exists $arg{letters} ? delete $arg{letters} : 'ascii';
    my $lines    = exists $arg{lines}   ? delete $arg{lines}   : 1;
    my ( @entries, @text );
    my $offset = 0;
    for my $number ( 1 .. @statuses ) {
        my $status = $statuses[ $number - 1 ];
        my ( $code, @rest ) = _unit( $number, $letters, $lines );
        my $first  = 1 + $lines * ( $number - 1 );
        my $column = 1 + index $code, q{+};
        my $start  = $offset + $column - 1;

        # A change of one line replaces the operator, and a change of two lines runs to the end of the second line.
        my $after  = @rest ? length( $rest[0] ) - 1           : 0;
        my $end    = @rest ? $offset + length($code) + $after : $start + 1;
        my $unit   = join q{}, $code, @rest;
        my $mutant = Test::Mutation::Mutant->new(
            id          => sprintf( '%012x', $number ),
            path        => $SAMPLE_PATH,
            mutator     => 'arithmetic',
            start       => $start,
            end         => $end,
            original    => substr( $unit, $column - 1, $end - $start ),
            replacement => @rest ? "-\n" : q{-},
            description => 'replaced + with -',
            from        => [ $first, $column ],
            to          => @rest ? [ $first + 1, $after + 1 ] : [ $first, $column + 1 ],
            scope       => [ $first, $first + @rest ],
        );
        push @entries,
          {
            mutant     => $mutant,
            status     => $status,
            reason     => _reason($status),
            detail     => _detail($status),
            by         => $status eq 'Killed'     ? $SAMPLE_TEST : undef,
            covered_by => $status eq 'NoCoverage' ? []           : [$SAMPLE_TEST],
            tests_run  => $status eq 'NoCoverage' ? 0            : 1,
            duration   => 0.25,
          };
        push @text, $unit;
        $offset += length $unit;
    }
    return Test::Mutation::Result->new(
        root              => '/project',
        sources           => { $SAMPLE_PATH => join q{}, @text },
        tests             => [ { name => $SAMPLE_TEST, duration => 0.5 } ],
        entries           => \@entries,
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 2,
        parallel_safe     => 1,
        started           => 100,
        finished          => 101.5,
        %arg,
    );
}

1;
