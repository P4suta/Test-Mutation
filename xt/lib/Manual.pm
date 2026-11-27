package Manual;
use v5.36;
use Test::Mutation::Commands;
use Test::Mutation::Environment;
use Test::Mutation::Exit;
use Test::Mutation::Message;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Settings;
use Test::Mutation::Status;

sub _code ($text) {
    return $text =~ /[<>]/ ? "C<< $text >>" : "C<$text>";
}

sub _sentence ($text) {
    return $text if $text =~ /[.?!]\z/;
    return ucfirst($text) . q{.};
}

sub _item ( $label, @lines ) {
    return "=item " . _code($label) . "\n\n" . join( "\n", @lines );
}

sub _setting ($row) {
    my @lines = ( _sentence( $row->help ) );
    push @lines, 'The configuration key is ' . _code( $row->key ) . q{.}   if $row->offers('file');
    push @lines, 'The Perl argument is ' . _code( $row->attribute ) . q{.} if $row->offers('call');
    push @lines, 'The default is ' . ( $row->default_text eq q{.} ? _code(q{.}) : $row->default_text ) . q{.}
      if length $row->default_text;
    my @flags = $row->offers('line') ? ( $row->flag ) : ( $row->name );
    push @flags, $row->short          if defined $row->short;
    push @flags, '--no-' . $row->name if $row->offers('line') && $row->kind eq 'flag';
    return _item( join( ', ', @flags ), @lines );
}

my @sections = (
    [
        COMMANDS => sub {
            return (
                ( map { _item( $_->usage, _sentence( $_->summary ) ) } Test::Mutation::Commands::rows()->@* ),
                (
                    map { _item( 'mutation ' . $_->{words}[0], _sentence( $_->{summary} ) ) }
                      Test::Mutation::Commands::switches()->@*
                )
            );
        }
    ],
    [
        SETTINGS => sub {
            return map { _setting($_) } Test::Mutation::Settings::rows()->@*;
        }
    ],
    [
        STATUSES => sub {
            return map {
                _item( $_->name, _sentence( $_->description ), 'The report schema uses ' . _code( $_->schema ) . q{.} )
            } Test::Mutation::Status::rows()->@*;
        }
    ],
    [
        'EXIT STATUS' => sub {
            return map { _item( 'status ' . $_->code, _sentence( $_->meaning ) ) } Test::Mutation::Exit::rows()->@*;
        }
    ],
    [
        ENVIRONMENT => sub {
            return map { _item( $_->{name}, $_->{meaning} ) } Test::Mutation::Environment::rows()->@*;
        }
    ],
    [
        DIAGNOSTICS => sub {
            return map { _item( $_->id, _code( $_->text ), $_->description ) } Test::Mutation::Message::rows()->@*;
        }
    ],
    [
        MUTATORS => sub {
            return map {
                _item(
                    $_->name,
                    _sentence( $_->description ),
                    'The ' . _code( $_->profile ) . ' profile includes the mutator.'
                )
            } Test::Mutation::Mutator::Catalog::mutators()->@*;
        }
    ],
);

sub sections () {
    return map { $_->[0] } @sections;
}

sub render ($template) {
    my %content = map { $_->[0] => $_->[1] } @sections;
    my %seen;
    $template =~ s{^=for generated ([A-Z ]+)\n\n(.*?)^=for end generated ([A-Z ]+)$}{
        my ($name, $end) = ($1, $3);
        die "invalid manual section $name / $end\n" unless $name eq $end && exists $content{$name} && !$seen{$name}++;
        join "\n\n", "=for generated $name", '=over 4', $content{$name}->(), '=back', "=for end generated $name";
    }egms;
    for my $name ( sections() ) {
        die "missing manual section $name\n" unless $seen{$name};
    }
    return $template;
}

1;
