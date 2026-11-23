package Test::Mutation::Record;
use v5.36;
use Types::Standard qw(ArrayRef Bool Dict HashRef Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

my $LINES  = HashRef [Bool];
my $RECORD = Dict [
    served      => HashRef [ Dict [ traced => Bool, hits => $LINES ] ],
    compiled    => HashRef [Bool],
    load_failed => HashRef [Bool],
    bypassed    => HashRef [Bool],
    breakable   => HashRef [$LINES],
    errors      => ArrayRef [Str],
];

my %APPLY = (
    served => sub ( $record, $traced, $path, $value ) {
        my $file = _served( $record, $path );
        $file->{traced} = 0 if !$traced;
        return;
    },
    hit => sub ( $record, $traced, $path, $value ) {
        _served( $record, $path )->{hits}{$value} = 1 if length $value;
        return;
    },
    lines => sub ( $record, $traced, $path, $value ) {
        $record->{breakable}{$path}{$_} = 1 for grep { length } split /,/, $value;
        return;
    },
    compiled => sub ( $record, $traced, $path, $value ) {
        $record->{compiled}{$path} = 1;
        return;
    },
    loadfail => sub ( $record, $traced, $path, $value ) {
        $record->{load_failed}{$path} = 1;
        return;
    },
    bypass => sub ( $record, $traced, $path, $value ) {
        $record->{bypassed}{$path} = 1;
        return;
    },
    error => sub ( $record, $traced, $path, $value ) {
        push $record->{errors}->@*, "$path: $value";
        return;
    },
);

signature_for parse => ( positional => [ ArrayRef [Str] ], returns => $RECORD );

sub parse ($texts) {
    my %record = ( served => {}, compiled => {}, load_failed => {}, bypassed => {}, breakable => {}, errors => [] );
    for my $text ( $texts->@* ) {
        my $traced = 0;
        for my $line ( split /\n/, $text ) {
            my ( $kind, $path, $value ) = split /\t/, $line, 3;
            next if !defined $kind || !defined $path;
            if ( $kind eq 'begin' ) {
                $traced = $path ? 1 : 0;
                next;
            }
            my $apply = $APPLY{$kind} or next;
            $apply->( \%record, $traced, $path, defined $value ? $value : q{} );
        }
    }
    return \%record;
}

sub _served ( $record, $path ) {
    my $served = $record->{served};
    $served->{$path} = { traced => 1, hits => {} } if !exists $served->{$path};
    return $served->{$path};
}

signature_for read_directory => ( positional => [Str], returns => $RECORD );

sub read_directory ($directory) {
    my @texts;
    for my $path ( sort glob "$directory/*.rec" ) {
        open my $handle, '<:raw', $path or die "cannot read $path: $!\n";
        local $/ = undef;
        my $text = readline $handle;
        push @texts, $text if defined $text;
        close $handle or die "cannot close $path: $!\n";
    }
    return parse( \@texts );
}

1;

__END__

=head1 NAME

Test::Mutation::Record - read what the shim recorded about one test run

=head1 SYNOPSIS

    my $record = Test::Mutation::Record::read_directory($directory);
    my $loaded = exists $record->{served}{$path};

=head1 FUNCTIONS

=head2 parse

Folds the texts of the record files of one test run into one record.
C<served> maps each target that the hook served to its trace state and the lines that ran.
A target counts as traced when every process that loaded it was tracing.
C<compiled>, C<load_failed>, and C<bypassed> name the targets with those events.
C<breakable> maps a target to the lines that hold a runtime statement.

=head2 read_directory

Reads every record file in a directory and parses them.

=cut
