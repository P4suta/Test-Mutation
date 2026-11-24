package Test::Mutation::CLI::Arguments;
use v5.36;
use Types::Standard qw(ArrayRef Dict Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Commands;
use Test::Mutation::Error;
use Test::Mutation::Settings;

our $VERSION = '0.001';

# The words that select a command, and the options that answer without a project.
my ( %COMMAND, %ANSWER, @ANSWERS );
for my $command ( Test::Mutation::Commands::rows()->@* ) {
    for my $word ( $command->words->@* ) {
        if ( $word =~ /\A-/ ) {
            $ANSWER{$word} = $command->name;
            push @ANSWERS, $word;
        }
        else {
            $COMMAND{$word} = $command->name;
        }
    }
}

# Every spelling of a setting on the command line: its flag, the negation of a flag, and its short option.
my ( %OPTION, @SPELLINGS );
for my $setting ( grep { $_->offers('line') } Test::Mutation::Settings::rows()->@* ) {
    my @spelled = (
        [ $setting->flag, 1 ],
        ( $setting->kind eq 'flag' ? [ '--no-' . $setting->name, 0 ] : () ),
        ( defined $setting->short ? [ $setting->short, 1 ] : () ),
    );
    for my $spelling (@spelled) {
        $OPTION{ $spelling->[0] } = { setting => $setting, on => $spelling->[1] };
        push @SPELLINGS, $spelling->[0];
    }
}

# What one word says, apart from the value that the option before it may take.
sub _item ($word) {
    if ( my ( $spelled, $text ) = $word =~ /\A(--[^=]+)=(.*)\z/s ) {
        my $option = $OPTION{$spelled};
        return { unknown => $spelled } if !$option && !$ANSWER{$spelled};
        return { option  => $option, spelled => $spelled, text => $text }
          if $option && $option->{setting}->kind ne 'flag';
        return { without => $spelled };
    }
    return { answer => $ANSWER{$word} } if $ANSWER{$word};
    if ( my $option = $OPTION{$word} ) {
        my $valued = $option->{setting}->kind ne 'flag';
        return { option => $option, spelled => $word, wants => $valued };
    }
    if ( my ( $short, $text ) = $word =~ /\A(-[[:alpha:]])(.+)\z/s ) {
        my $option = $OPTION{$short};
        return { option => $option, spelled => $short, text => $text }
          if $option && $option->{setting}->kind ne 'flag';
    }
    return $word =~ /\A-./ ? { unknown => $word } : { operand => $word };
}

# The words in order: an option takes the next word as its value unless that word is an option of its own.
# Every word behind two dashes is an operand.
sub _items ($argv) {
    my ( @items, $behind, $waiting );
    for my $word ( $argv->@* ) {
        if ( $waiting && $word !~ /\A--/ ) {
            $waiting->{text} = $word;
            $waiting = undef;
            next;
        }
        $waiting = undef;
        if ($behind) {
            push @items, { operand => $word, behind => 1 };
            next;
        }
        if ( $word eq q{--} ) {
            $behind = 1;
            next;
        }
        push @items, _item($word);
        $waiting = $items[-1] if $items[-1]{wants};
    }
    return @items;
}

# The spellings that a command takes, for the name nearest to one that it lacks.
sub _spellings ($command) {
    return [ ( grep { _accepts( $OPTION{$_}{setting}, $command ) } @SPELLINGS ), @ANSWERS ];
}

sub _accepts ( $setting, $command ) {
    return scalar grep { $_ eq $command } $setting->commands->@*;
}

# The value of one option, or the refusal of the word that set it.
sub _value ( $item, $command ) {
    Test::Mutation::Error::raise(
        'option-unknown',
        option  => $item->{unknown},
        nearest => Test::Mutation::Settings::nearest( $item->{unknown}, _spellings($command) )
    ) if defined $item->{unknown};
    Test::Mutation::Error::raise( 'option-with-value', option => $item->{without} ) if defined $item->{without};
    my ( $option, $spelled ) = $item->@{qw(option spelled)};
    my $setting = $option->{setting};
    Test::Mutation::Error::raise( 'option-elsewhere', option => $spelled, command => $command )
      if !_accepts( $setting, $command );
    return $option->{on}                                                       if $setting->kind eq 'flag';
    Test::Mutation::Error::raise( 'option-without-value', option => $spelled ) if !defined $item->{text};
    return Test::Mutation::Settings::decode( setting => $setting, given => $item->{text}, spelled => $spelled );
}

signature_for parse => (
    named   => [ argv => ArrayRef [Str] ],
    returns => Dict [ command => Str, operands => ArrayRef [Str], given => Test::Mutation::Settings::layer_type() ],
);

sub parse ($arg) {
    my @items    = _items( $arg->argv );
    my @operands = map  { $_->{operand} } grep { defined $_->{operand} } @items;
    my ($first)  = grep { defined $_->{operand} && !$_->{behind} } @items;
    my $command  = $first && $COMMAND{ $first->{operand} };
    shift @operands if $command;
    my %given = ( origin => 'line', name => undef, entries => {} );
    my ($answer) = grep { $_->{answer} } @items;
    return { command => $answer->{answer}, operands => \@operands, given => \%given } if $answer;

    $command = 'run' if !$command;
    my $entries = $given{entries};
    for my $item ( grep { !defined $_->{operand} } @items ) {
        my $value   = _value( $item, $command );
        my $setting = $item->{option}{setting};
        $value = [ ( $entries->{ $setting->name } ? $entries->{ $setting->name }{value}->@* : () ), $value ]
          if $setting->kind eq 'list';
        $entries->{ $setting->name } = { value => $value, spelled => $item->{spelled}, surface => 'line' };
    }
    return { command => $command, operands => \@operands, given => \%given };
}

1;

__END__

=head1 NAME

Test::Mutation::CLI::Arguments - read the command line of mutation

=head1 SYNOPSIS

    my $parsed = Test::Mutation::CLI::Arguments::parse( argv => [ 'list', '--jobs', 4 ] );
    say $parsed->{command};                                # list
    say $parsed->{given}{entries}{jobs}{value};            # 4

=head1 DESCRIPTION

The parser reads the words of the command line with the table of the settings and the table of the commands.
The first word that is neither an option nor its value names the command, and C<run> stands for none.
An option takes its value after an equals sign or in the next word, unless that word starts with two dashes.
A short option of a value may also hold it in the same word, as C<-j4> does.
A flag takes no value, and C<--no-> before its name sets it off.
Every word behind two dashes is an operand.

C<--help>, C<-h>, and C<--version> answer wherever they stand before the two dashes, before any other check.
The parser takes no abbreviation of an option.
A refusal names the option as the user wrote it, and an unknown option comes with the nearest one that the command takes.

=head1 FUNCTIONS

=head2 parse

Returns the C<command>, its C<operands>, and the settings as a layer of L<Test::Mutation::Settings> in C<given>.
The value of a list holds every word that the user gave it, and every other setting takes its last word.
For a word that answers without a project, the command is C<help> or C<version>, and C<given> holds no setting.
The function dies with a usage error of L<Test::Mutation::Error> at the first word that it refuses.

=cut
