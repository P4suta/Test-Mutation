use v5.36;
use Test2::V0;
use File::Temp ();
use TOML::Tiny ();
use lib 't/lib', 't/contract/lib', 't/e2e/lib';
use Fixture qw(copy_of);
use Gate;
use Library;
use Sources;
use Space;
use World;
use Test::Mutation::Commands;
use Test::Mutation::Config;
use Test::Mutation::Exit;
use Test::Mutation::Settings;
use Test::Mutation::Status;
use Test::Mutation::Types ();

# S9, the documentation: every verbatim block and every code reference of the command and the library.
# An example runs or matches a table, a reference names something that exists, and the manual names every row of the tables.
# No section of the manual comes from a table yet, so each row that the manual leaves out is an open finding.

my $project  = copy_of('calc');
my @commands = Test::Mutation::Commands::rows()->@*;
my @settings = Test::Mutation::Settings::rows()->@*;
my @statuses = map { $_->name } Test::Mutation::Status::rows()->@*;
my @types    = Test::Mutation::Types->type_names;
my %usage    = map { $_->usage =~ s/ \[options\]//r => 1 } @commands;
my %word     = map { $_ => 1 } map { $_->words->@* } @commands;
my %flag     = (
    %word, map { $_->flag => 1, ( $_->negatable ? ( '--no-' . substr( $_->flag, 2 ) => 1 ) : () ) } Space::flags()->@*
);

# The kind of a verbatim block: command lines, a piece of the configuration file, or Perl code.
sub kind ($block) {
    my @lines = grep { length } split /\n/, $block;
    return 'commands' if !grep { !/\Amutation(?: |\z)/ } @lines;
    return 'settings' if !grep { !/\A(?:\[[\w-]+\]|[\w-]+ = \S.*)\z/ } @lines;
    return 'perl';
}

sub planned ($line) {
    my ( undef, @words ) = split q{ }, $line;
    my $plan = World::observe( \@words, cwd => $project, run => 'cheap' )->{plan};
    return $plan && !$plan->{refused} ? 1 : 0;
}

# What is wrong with a block of command lines or of the configuration file, or nothing.
sub broken ( $kind, $block ) {
    if ( $kind eq 'commands' ) {
        my @lines = grep { length } split /\n/, $block;
        my @usage = grep { /[[:upper:]]{2}|\[/ } @lines;
        return 'a usage line that no command has' if grep { !$usage{s/ \[options\]//r} } @usage;
        return 'a command line that the command refuses' if grep { !planned($_) } grep { !/[[:upper:]]{2}|\[/ } @lines;
        return;
    }
    my ( $data, $error ) = TOML::Tiny::from_toml($block);
    return 'a configuration that the decoder refuses' if !defined $data;
    my $config =
      eval { Test::Mutation::Config->from_layers( root => $project, defaults => {}, cli => {}, file => $data ) };
    return $config ? () : 'a configuration that the command refuses';
}

# The blocks of Perl code that do not compile, each as its place in the list.
sub uncompiled (@blocks) {
    my $compile = sub (@numbers) {
        my $file = File::Temp->new( SUFFIX => '.pl' );
        print {$file} "use v5.36;\n", map { "{ no strict; no warnings; sub {\n$blocks[$_]\n} }\n" } @numbers
          or die "write: $!";
        close $file or die "close: $!";
        my $output = qx{$^X -Ilib -c $file 2>&1};
        return $output =~ /syntax OK/ ? 1 : 0;
    };
    return if !@blocks || $compile->( 0 .. $#blocks );
    return grep { !$compile->($_) } 0 .. $#blocks;
}

# What a code reference names, where its form says so: a command line, a flag, or a status.
sub unresolved ($reference) {
    my ( $first, @rest ) = split q{ }, $reference;
    if ( $first eq 'mutation' ) {
        my ($command) = grep { !/\A-/ } @rest;
        return 'a command that no table names' if defined $command && !$word{$command} && $command !~ /[[:upper:]]/;
        return 'a flag that no table names'    if grep { /\A--/ && !$flag{$_} } @rest;
        return;
    }
    return $flag{$first} ? () : 'a flag that no table names' if $first =~ /\A--[[:lower:]][[:lower:]-]*[[:lower:]]\z/;

    # A word of capitals and small letters has the form of a status, and a type of the shared library has that form too.
    return ( grep { $_ eq $reference } @statuses, @types ) ? () : 'a status that no table names'
      if $reference =~ /\A(?:[[:upper:]][[:lower:]]+)+\z/;
    return 'no check';
}

subtest 'the reader of the documentation rejects an example that the command refuses' => sub {
    my $pod =
        "1;\n__END__\n\n=head1 SYNOPSIS\n\n    mutation run\n    mutation lst\n\n    jobs = 4\n\n    my \$x = f( 1;\n\n"
      . "See C<--jobs>, C<< mutation run --since origin/main >>, and C<Killed>.\n\n=cut\n";
    my $read = Sources::documentation($pod);
    is $read->{blocks}, [ "mutation run\nmutation lst", 'jobs = 4', 'my $x = f( 1;' ],
      'the verbatim blocks without their indent';
    is $read->{references}, [ '--jobs', 'mutation run --since origin/main', 'Killed' ], 'the code references';
    is [ map { kind($_) } $read->{blocks}->@* ], [qw(commands settings perl)],          'the kind of each block';
    is [ broken( 'commands', "mutation run\nmutation lst" ) ], ['a command line that the command refuses'],
      'a misspelt command';
    is [ broken( 'commands', "mutation run\nmutation show 0123456789ab" ) ], [], 'command lines that the command plans';
    is [ broken( 'commands', 'mutation show ID NAME' ) ], ['a usage line that no command has'], 'another usage line';
    is [ broken( 'settings', 'jobs = 4' ) ],              [], 'a key of the configuration file';
    is [ broken( 'settings', 'speed = 4' ) ], ['a configuration that the command refuses'], 'an unknown key';
    is [ uncompiled( 'my $x = f(1);', 'my $x = f( 1;', 'say 1;' ) ], [1], 'the block with a syntax error';
    is [
        map { unresolved($_) } '--jobs', '--jobz', 'mutation run --since x', 'mutation lst',
        'Killed',                        'Facts',  'NoVerdict',              'local'
      ],
      [ 'a flag that no table names', 'a command that no table names', 'a status that no table names', 'no check' ],
      'a reference that names nothing, and one whose form names no table';
};

my @files = ( 'bin/mutation', Library::modules()->@* );
my %read  = map { $_ => Sources::documentation( Sources::slurp($_) ) } @files;
my ( @examples, @symbols,    %kinds );
my ( $blocks,   $references, $resolved ) = ( 0, 0, 0 );
for my $file (@files) {
    my @blocks = $read{$file}{blocks}->@*;
    my @kind   = map { kind($_) } @blocks;
    $blocks += @blocks;
    $kinds{$_}++ for @kind;
    push @examples, map { [ broken( $kind[$_], $blocks[$_] ), $kind[$_], $file ] }
      grep { $kind[$_] ne 'perl' && broken( $kind[$_], $blocks[$_] ) } 0 .. $#blocks;
    my @perl = grep { $kind[$_] eq 'perl' } 0 .. $#blocks;
    push @examples, map { [ 'code that does not compile', 'perl', $file ] } uncompiled( @blocks[@perl] );
    for my $reference ( $read{$file}{references}->@* ) {
        my ($problem) = unresolved($reference);
        $references++;
        $resolved++ if !defined $problem || $problem ne 'no check';
        push @symbols, [ $problem, $reference =~ tr/ /_/r, $file ] if defined $problem && $problem ne 'no check';
    }
}
Gate::findings( 'contract-examples-manual', Space::folded( \@examples, 'kinds',      'files' ) );
Gate::findings( 'contract-symbols-manual',  Space::folded( \@symbols,  'references', 'files' ) );
Gate::checked( 'verbatim blocks',                       $blocks,          at_least => 55 );
Gate::checked( 'blocks of command lines',               $kinds{commands}, at_least => 2 );
Gate::checked( 'blocks of the configuration file',      $kinds{settings}, at_least => 5 );
Gate::checked( 'code references',                       $references,      at_least => 280 );
Gate::checked( 'code references that a table resolves', $resolved,        at_least => 20 );

# manual: the manual names every row of every table.
my $manual = join q{}, map { $read{$_}{text} } 'bin/mutation', 'lib/Test/Mutation.pm';
my @blocks = map { $read{$_}{blocks}->@* } 'bin/mutation', 'lib/Test/Mutation.pm';
my %key;
for my $block ( grep { kind($_) eq 'settings' } @blocks ) {
    my ($data) = TOML::Tiny::from_toml($block);
    for my $section ( sort keys %{ $data || {} } ) {
        my $value = $data->{$section};
        $key{ ref $value eq 'HASH' ? "$section.$_" : ".$section" } = 1
          for ref $value eq 'HASH' ? sort keys $value->%* : q{};
    }
}
my @unnamed;
for my $command (@commands) {
    push @unnamed, [ 'the manual names no row of the table', $command->name, 'commands' ]
      if !grep { $manual =~ /\bmutation (?:\[)?\Q$_\E/ } $command->words->@*;
}
push @unnamed, map { [ 'the manual names no row of the table', $_->flag, 'flags' ] }
  grep { $manual !~ /(?<![\w-])\Q@{[ $_->flag ]}\E(?![\w-])/ } Space::flags()->@*;
push @unnamed, map { [ 'the manual names no row of the table', join( q{.}, $_->key->@* ), 'keys' ] }
  grep { !$key{ join q{.}, $_->key->@* } } grep { $_->key } @settings;
push @unnamed,
  map { [ 'the manual names no row of the table', $_, 'statuses' ] } grep { $manual !~ /C<\Q$_\E>/ } @statuses;
push @unnamed, map { [ 'the manual names no row of the table', $_->code, 'exit-statuses' ] }
  grep { $manual !~ /\bstatus \Q@{[ $_->code ]}\E\b/ } Test::Mutation::Exit::rows()->@*;
Gate::findings( 'contract-manual-manual', Space::folded( \@unnamed, 'rows', 'tables' ) );
Gate::checked(
    'rows of the tables',
    @commands + Space::flags()->@* + @statuses + 8 + grep( { $_->key } @settings ),
    at_least => 60
);

done_testing;
