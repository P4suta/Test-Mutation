use v5.36;
use Test2::V0;
use lib 't/lib';
use Raised;
use Test::Mutation::CLI::Arguments;

# The parser of the command line: the command, its operands, and the settings as the user wrote them.

sub parsed (@argv) {
    return Test::Mutation::CLI::Arguments::parse( argv => \@argv );
}

# The command, the operands, and each setting as its value and the spelling that set it.
sub read_as (@argv) {
    my $parsed  = parsed(@argv);
    my $entries = $parsed->{given}{entries};
    return [
        $parsed->{command}, $parsed->{operands},
        { map { $_ => [ $entries->{$_}{value}, $entries->{$_}{spelled} ] } keys $entries->%* }
    ];
}

sub refused (@argv) {
    my $error = Raised::error( sub { parsed(@argv) } );
    return ref $error ? [ $error->@[ 1, 2 ] ] : $error;
}

subtest 'the command and its operands' => sub {
    is read_as(), [ 'run', [], {} ], 'run without a word';
    is read_as( 'list',   'lib/A.pm' ), [ 'list', ['lib/A.pm'], {} ], 'the first word names the command';
    is read_as( 'run',    'list' ),     [ 'run',  ['list'],     {} ], 'and only the first word';
    is read_as( '--root', q{.}, 'show', 'a' ), [ 'show', ['a'], { root => [ q{.}, '--root' ] } ],
      'the word after the options before it';
    is read_as( q{--}, 'list' ), [ 'run', ['list'], {} ], 'no word behind the two dashes names a command';
    is read_as( 'exec', 'a', q{--}, 'prove', '--jobs', '2', q{-} ),
      [ 'exec', [ 'a', 'prove', '--jobs', '2', q{-} ], {} ],
      'every word behind the two dashes is an operand';
    is read_as( 'list', q{-} ),   [ 'list', [q{-}], {} ], 'and so is a dash alone';
    is parsed()->{given}{origin}, 'line',                 'the settings come from the command line';
};

subtest 'each way to write a setting' => sub {
    is read_as( '--jobs', 2 )->[2], { jobs => [ 2, '--jobs' ] }, 'a value in the next word';
    is read_as('--jobs=2')->[2],    { jobs => [ 2, '--jobs' ] }, 'a value after an equals sign';
    is read_as( '-j', 2 )->[2],     { jobs => [ 2, '-j' ] },     'a short option';
    is read_as('-j2')->[2],         { jobs => [ 2, '-j' ] },     'and its value in the same word';
    is read_as( '--jobs', 2, '--jobs', 3 )->[2], { jobs => [ 3, '--jobs' ] }, 'the last value of a setting';
    is read_as( '--source', 'a', '-C', q{.}, '--source', 'b' )->[2],
      { source => [ [ 'a', 'b' ], '--source' ], root => [ q{.}, '-C' ] }, 'every value of a list';
    is read_as( '--switch', '-Ilib', '--switch=-T' )->[2], { switch => [ [ '-Ilib', '-T' ], '--switch' ] },
      'a value that starts with one dash';
    is read_as('--source=')->[2],  { source => [ [q{}], '--source' ] }, 'an empty value';
    is read_as('--cache')->[2],    { cache  => [ 1, '--cache' ] },    'a flag';
    is read_as('--no-cache')->[2], { cache  => [ 0, '--no-cache' ] }, 'a negated flag';
    is read_as( '--no-cache', '--cache' )->[2], { cache => [ 1, '--cache' ] }, 'the last word of a flag';
    is read_as( 'list', '--jobs', 2, 'x' )->[1], ['x'], 'an operand after a setting';
};

subtest 'the help and the version wherever they stand' => sub {
    is [ map { parsed( $_->@* )->{command} } ['--help'], ['-h'], ['--version'], [ 'list', '--jobs', 2, '-h' ] ],
      [qw(help help version help)], 'the word anywhere before the two dashes';
    is parsed( '--version', '--help' )->{command},            'version',                    'the first of them';
    is parsed( 'list', '--bogus', '--help' )->{command},      'help',                       'before a refusal';
    is parsed( 'list', '--jobs', '--help' )->{command},       'help',                       'and in place of a value';
    is read_as( '--version', 'extra' ),                       [ 'version', ['extra'], {} ], 'with the operands';
    is read_as( 'exec', 'a', q{--}, 'prove', '--help' )->[0], 'exec', 'behind the two dashes the word is an operand';
};

subtest 'the refusals, each with the spelling of the user' => sub {
    is refused( '--jobs', 'x' ), [ 'setting-invalid', '--jobs takes a whole number above zero, not x' ], 'a value';
    is refused( '-j', 0 ), [ 'setting-invalid', '-j takes a whole number above zero, not 0' ], 'of a short option';
    is refused('-jx'),     [ 'setting-invalid', '-j takes a whole number above zero, not x' ], 'in the same word';
    is refused('--jobs'),  [ 'option-without-value', '--jobs needs a value' ], 'a value that the line lacks';
    is refused( '--jobs', '--cache' ), [ 'option-without-value', '--jobs needs a value' ],
      'a value in place of which an option stands';
    is refused( '--jobs', '--cache', '2' ), [ 'option-without-value', '--jobs needs a value' ],
      'and the word after that option stays an operand';
    is refused( '--jobs', q{--}, '2' ), [ 'option-without-value', '--jobs needs a value' ],
      'and so does a word behind two dashes';
    is refused('-j'),          [ 'option-without-value', '-j needs a value' ],          'and of a short option';
    is refused('--cache=1'),   [ 'option-with-value',    '--cache takes no value' ],    'a value for a flag';
    is refused('--no-cache='), [ 'option-with-value',    '--no-cache takes no value' ], 'and for its negation';
    is refused('--help=1'),    [ 'option-with-value',    '--help takes no value' ],     'and for the help';
    is refused( '--jo', 2 ), [ 'option-unknown', '--jo names no option; the nearest is --jobs' ],   'an abbreviation';
    is refused('--jobz=2'),  [ 'option-unknown', '--jobz names no option; the nearest is --jobs' ], 'a misspelt option';
    is refused('--no-jobs'), [ 'option-unknown', '--no-jobs names no option; the nearest is --jobs' ],
      'the negation of a value';
    is refused('--min_score'), [ 'option-unknown', '--min_score names no option; the nearest is --min-score' ],
      'the name of another surface';
    is refused('-x'), [ 'option-unknown', '-x names no option; the nearest is -C' ], 'a short option';
    is refused( 'mutators', '--jobs', 2 ), [ 'option-elsewhere', '--jobs is no option of mutators' ],
      'an option of another command';
    is refused( 'mutators', '--jobz' ), [ 'option-unknown', '--jobz names no option; the nearest is --root' ],
      'and the nearest among the options of the command';
    is refused( '--jobz', '--cache=1' ), [ 'option-unknown', '--jobz names no option; the nearest is --jobs' ],
      'the first refusal';
    is refused( '--cache=1', '--jobz' ), [ 'option-with-value', '--cache takes no value' ], 'in the order of the words';
    is refused( '--jobs', 0, '--jobz' ), [ 'setting-invalid', '--jobs takes a whole number above zero, not 0' ],
      'a value before an unknown option';
};

done_testing;
