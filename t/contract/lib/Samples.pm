package Samples;
use v5.36;
use Test::Mutation::Mutant;
use Test::Mutation::Result;

# The sample values of every type of a setting, in one place.
# `isa` is the name of the type of one value in the configuration, and `letter` is the argument type of the option parser.
# A type that the configuration checks has samples outside it, and a type that is plain text has none.
my %TYPE = (
    'positive-integer' => { isa => 'PositiveInt', letter => 'i', valid => [ 2, 16 ], invalid => [ 0, -1, '1.5', 'x' ] },
    'positive-number'  => { isa => 'PositiveNum', letter => 'f', valid => [ 2, '0.5' ], invalid => [ 0, -1, 'x' ] },
    percent  => { isa => '__ANON__', letter => 'f', valid => [ 50, 0, 100, '99.5' ], invalid => [ -1, '100.5', 'x' ] },
    coverage => { isa => 'Enum["line","file"]', valid => [ 'file', 'line' ], invalid => ['branch'] },
    profile  => { isa => 'Enum["default","extended"]', valid => [ 'extended', 'default' ], invalid => ['nonesuch'] },
    format   => {
        isa     => 'Enum["terminal","json","html","github"]',
        valid   => [ 'json', 'terminal', 'html', 'github' ],
        invalid => ['pdf']
    },
    shard      => { isa => '__ANON__', valid => [ '2/3', '1/1' ], invalid => [ '0/3', '4/3', '2', 'a/b' ] },
    boolean    => { isa => 'Bool', valid => [ 1, 0 ], invalid => ['yes'] },
    directory  => { valid => [ 'out', 'reports/here' ] },
    file       => { valid => ['ci.toml'] },
    program    => { valid => ['/opt/perl/bin/perl'] },
    path       => { valid => [ 'vendor',      'local' ] },
    glob       => { valid => [ 'src/**/*.pm', 'lib/Calc.pm' ] },
    switch     => { valid => [ '-Ilib',       '-Mblib' ] },
    revision   => { valid => ['HEAD'] },
    identifier => { valid => [ '0123456789ab', 'ba9876543210' ] },
    mutator    => { valid => [ 'arithmetic', 'sub-body' ] },
);

sub type ($name) {
    my $type = $TYPE{$name} or die "no type is named $name\n";
    return { isa => 'Str', letter => 's', invalid => [], $type->%*, name => $name };
}

sub types () {
    return [ sort keys %TYPE ];
}

# The first words that name no command, each with the name that stands nearest to it.
my %NEAREST = (
    help    => '--help',
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
my %OPERANDS = ( show => ['0123456789ab'], exec => [ '0123456789ab', 'true' ], merge => ['part.json'] );

sub operands ( $command, $count ) {
    my @named = @{ $OPERANDS{$command} || [] };
    return [ map { defined $named[$_] ? $named[$_] : "surplus$_" } 0 .. $count - 1 ];
}

# A value as the text of a configuration file.
sub toml ( $type, $value ) {
    return $value ? 'true' : 'false' if $type->{name} eq 'boolean' && $value =~ /\A[01]\z/;
    return $value                    if $type->{letter} ne 's'     && $value =~ /\A-?[0-9]+(?:[.][0-9]+)?\z/;
    return q{"} . $value =~ s/(["\\])/\\$1/gr . q{"};
}

my $SAMPLE_PATH = 'lib/Sample.pm';
my $SAMPLE_TEST = 't/sample.t';

sub _line ($number) {
    return "sub f$number { return \$_[0] + $number }\n";
}

# A result with one mutant for each status, in a source with one line for each mutant.
sub result (%arg) {
    my @statuses = @{ delete $arg{statuses} || [] };
    my ( @entries, $offset );
    $offset = 0;
    for my $number ( 1 .. @statuses ) {
        my $status = $statuses[ $number - 1 ];
        my $column = 1 + index _line($number), q{+};
        my $mutant = Test::Mutation::Mutant->new(
            id          => sprintf( '%012x', $number ),
            path        => $SAMPLE_PATH,
            mutator     => 'arithmetic',
            start       => $offset + $column - 1,
            end         => $offset + $column,
            original    => q{+},
            replacement => q{-},
            description => 'replaced + with -',
            from        => [ $number, $column ],
            to          => [ $number, $column + 1 ],
            scope       => [ $number, $number ],
        );
        push @entries,
          {
            mutant => $mutant,
            status => $status,
            reason => $status eq 'Killed' ? "$SAMPLE_TEST failed" : $status eq 'Survived' ? undef : "reason of $status",
            by         => $status eq 'Killed'     ? $SAMPLE_TEST  : undef,
            covered_by => $status eq 'NoCoverage' ? []            : [$SAMPLE_TEST],
            tests_run  => $status eq 'NoCoverage' ? 0             : 1,
            duration   => 0.25,
          };
        $offset += length _line($number);
    }
    return Test::Mutation::Result->new(
        root              => '/project',
        sources           => { $SAMPLE_PATH => join q{}, map { _line($_) } 1 .. @statuses },
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
