use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Fixture qw(copy_of tree_digest write_file);
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::CLI;
use Test::Mutation::Commands;
use Test::Mutation::Exit;
use Test::Mutation::Runner;

# S1, the arguments: every form of every command with every way to write every flag.
# The tables say what each line calls for, and each violation of today is an open finding.

my $project = copy_of('calc');
write_file( "$project/ci.toml", "\n" );
my $before = tree_digest($project);
my @codes  = map { $_->code } Test::Mutation::Exit::rows()->@*;
my @forms  = Space::forms()->@*;

# A plan starts no analysis and no test, and this space carries out only refusals, the help, and the version.
my $started = 0;
{
    no warnings 'redefine';
    *Test::Mutation::Runner::analyze     = sub { $started++; die "this space starts no analysis\n" };
    *Test::Mutation::Runner::run         = sub { $started++; die "this space starts no run\n" };
    *Test::Mutation::Runner::run_command = sub { $started++; die "this space starts no command\n" };
}

my ( %violations, @broken );

# A violation of an invariant: what broke, and where, as a value of the named dimension and a command.
sub violation ( $gate, $dimension, $what, $one, $command ) {
    push $violations{$gate}{$dimension}->@*, [ $what, $one, $command ];
    return;
}

# The checks that every refusal meets, whatever asked for it.
sub refusal_checks ( $observation, $dimension, $variant, $one, $command, $typed, $foreign = undef ) {
    my %symptoms = (
        'exit-table' => [ Invariants::exit_table( $observation, 2 ) ],
        'one-line'   => [ Invariants::one_line($observation) ],
        'no-leak'    => [ Invariants::no_leak($observation) ],
        'typed-name' => [ defined $typed ? Invariants::typed_name( $observation, $typed, $foreign ) : () ],
    );
    for my $gate ( sort keys %symptoms ) {
        violation( $gate, $dimension, "$variant: $_", $one, $command ) for $symptoms{$gate}->@*;
    }
    return;
}

sub observed ($argv) {
    my $observation = World::observe( $argv, cwd => $project, run => 'cheap' );
    push @broken, "@$argv: $observation->{died}"                                        if defined $observation->{died};
    push @broken, map { "@$argv: $_" } Invariants::exit_domain( $observation, \@codes ) if defined $observation->{exit};
    return $observation;
}

subtest 'each flag of each setting on each command' => sub {
    my $cases = Space::arguments();
    my ( %seen, @wrong );
    for my $case ( $cases->@* ) {
        my ( $setting, $variant, $form ) = ( $case->{setting}, $case->{variant}, $case->{form}{label} );
        my $flag        = $setting->flag;
        my $observation = observed( $case->{argv} );
        my $plan        = $observation->{plan} or next;
        $seen{variant}{$variant} = $seen{flag}{$flag} = $seen{form}{$form} = 1;
        if ( $case->{expect} eq 'refuse' ) {
            if ( !$plan->{refused} ) {
                violation( $case->{breaks}, 'flags', "$variant: accepted", $flag, $form );
                next;
            }
            refusal_checks( $observation, 'flags', $variant, $flag, $form, $case->{typed},
                Space::foreign_name($setting) );
            my $near = $variant eq 'typo' && Space::accepts( $setting, $case->{form}{command}->name );
            violation( 'unknown', 'flags', "$variant: $_", $flag, $form )
              for $near ? Invariants::nearest( $observation, $flag ) : ();
            next;
        }
        if ( $plan->{refused} ) {
            violation( 'exit-table', 'flags', "$variant: refused", $flag, $form );
            next;
        }

        # A line that the tables accept sets its value and nothing else.
        my $attribute = $setting->attribute;
        next if !defined $case->{value} || !defined $attribute || $attribute eq 'root';
        my $value = $plan->{config}->$attribute;
        my $text  = ref $value ? join q{ }, $value->@* : $value;
        push @wrong, "@{ $case->{argv} }: $attribute is $text" if $text ne $case->{value};
    }
    my @variants = Space::variants()->@*;
    is \@wrong,                          [],                       'an accepted flag sets the value of its setting';
    is scalar $cases->@*,                Space::arguments_count(), 'the cases that the tables call for';
    is [ sort keys $seen{variant}->%* ], [ sort @variants ],       'every way to write a flag';
    is [ sort keys $seen{flag}->%* ],    [ sort map { $_->flag } Space::flags()->@* ], 'every flag';
    is [ sort keys $seen{form}->%* ],    [ sort map { $_->{label} } @forms ],          'every form of a command';
    Gate::checked( 'command lines with a flag', scalar $cases->@*, at_least => 2000 );
};

subtest 'the help and the version at every position' => sub {
    my %text = (
        help    => World::observe( ['--help'], cwd => $project )->{stdout},
        version => "mutation $Test::Mutation::CLI::VERSION\n",
    );
    my %answer;
    for my $command ( Test::Mutation::Commands::rows()->@* ) {
        $answer{$_} = $command->name for grep { /\A-/ } $command->words->@*;
    }
    my @words = sort keys %answer;
    my ( $count, $expected ) = ( 0, 0 );
    for my $form (@forms) {
        my $command = $form->{command};
        my @base    = Space::line( $form, [], $command->least )->@*;
        my ($end)   = grep { $base[$_] eq q{--} } 0 .. $#base;

        # A word behind the two dashes of exec belongs to the command that exec runs.
        $expected +=
          @words * ( ( defined $form->{word} ? 1 : 0 ) + ( $command->name eq 'exec' ? 1 : $command->least ) + 1 );
        for my $position ( 0 .. ( defined $end ? $end : scalar @base ) ) {
            for my $word (@words) {
                my @line = @base;
                splice @line, $position, 0, $word;
                violation( 'help', 'positions', "$word: $_", $position ? 'later' : 'first', $form->{label} )
                  for Invariants::help( observed( \@line ), $text{ $answer{$word} } );
                $count++;
            }
        }
    }
    is $count, $expected, 'the positions that the tables call for';

    my ($options) = $text{help} =~ /\nOptions:\n(.*)\z/s;
    my %printed   = map { $_ => 1 } $options =~ /(?<![\w-])(--?[[:alpha:]][\w-]*)/g;
    my %accepted  = map { $_ => 1 } @words;
    for my $setting ( Space::flags()->@* ) {
        $accepted{$_} = 1 for $setting->flag, ( defined $setting->short ? $setting->short : () );
        $accepted{ '--no-' . substr $setting->flag, 2 } = 1 if $setting->kind eq 'flag';
    }
    violation( 'help', 'options', 'the help text lacks an option that the commands accept', $_, 'help' )
      for grep { !$printed{$_} } sort keys %accepted;
    violation( 'help', 'options', 'the help text prints an option that no command accepts', $_, 'help' )
      for grep { !$accepted{$_} } sort keys %printed;
    Gate::checked( 'positions of the help and the version', $count,                  at_least => 40 );
    Gate::checked( 'options of the help text',              scalar( keys %printed ), at_least => 24 );
};

subtest 'every count of operands from none to one more than the most' => sub {
    my ( $count, $expected ) = ( 0, 0 );
    for my $form (@forms) {
        my $command = $form->{command};
        my ( $least, $most ) = ( $command->least, $command->most );
        my $highest = ( defined $most ? $most : $least ) + 1;
        $expected += $highest + 1;
        for my $operands ( 0 .. $highest ) {
            my $observation = observed( Space::line( $form, [], $operands ) );
            my $plan        = $observation->{plan} or next;
            my $fits        = $operands >= $least && ( !defined $most || $operands <= $most );
            my @where       = ( 'counts', 'operands', $operands, $form->{label} );
            $count++;
            if ( !$plan->{refused} ) {
                violation( 'stray', 'counts', 'operands: accepted', $operands, $form->{label} ) if !$fits;
            }
            elsif ($fits) {
                violation( 'exit-table', 'counts', 'operands: refused', $operands, $form->{label} );
            }
            else {
                refusal_checks( $observation, @where, $operands > $least ? 'surplus' . ( $operands - 1 ) : undef );
            }
        }
    }
    is $count, $expected, 'the counts that the tables call for';
    Gate::checked( 'counts of operands', $count, at_least => 18 );
};

subtest 'every first word that names no command' => sub {
    my %nearest = Samples::words_without_command()->%*;
    my %command = map { $_ => 1 } map { $_->words->@* } Test::Mutation::Commands::rows()->@*;
    is [ grep { $command{$_} } sort keys %nearest ], [], 'no sample word is a command';
    for my $word ( sort keys %nearest ) {
        my $observation = observed( [$word] );
        my $plan        = $observation->{plan} or next;
        if ( !$plan->{refused} ) {
            violation( 'unknown', 'words', 'first word: accepted', $word, 'default' );
            next;
        }
        refusal_checks( $observation, 'words', 'first word', $word, 'default', $word );
        violation( 'unknown', 'words', "first word: $_", $word, 'default' )
          for Invariants::nearest( $observation, $nearest{$word} );
    }
    Gate::checked( 'first words without a command', scalar( keys %nearest ), at_least => 10 );
};

is \@broken, [], 'no plan dies, and every exit status stands in the table';

# no-effect: a usage error leaves the project as it was and starts no test.
my @effects = (
    ( $started ? 'a refusal started the runner' : () ),
    ( map { "the project changed: $_" } Space::differences( $before, tree_digest($project) )->@* )
);
Gate::findings( 'contract-no-effect-arguments', \@effects );

for my $gate (qw(exit-table one-line no-leak typed-name no-abbrev stray help unknown)) {
    my $found = $violations{$gate} || {};
    Gate::findings( "contract-$gate-arguments",
        [ map { Space::folded( $found->{$_}, $_, 'commands' )->@* } sort keys $found->%* ] );
}

done_testing;
