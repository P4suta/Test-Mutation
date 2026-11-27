package Test::Mutation::Report::Live;
use v5.36;
use List::Util      qw(max);
use Types::Standard qw(Bool CodeRef FileHandle GlobRef Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Report::Progress;

our $VERSION = '0.001';

my $INTERVAL = 5;

my %HANDLER = (
    phase         => \&_enter,
    analyzed      => \&_analyzed,
    baseline_test => sub ( $view, $data, $now ) { $view->{tested}++; return },
    baseline      => sub ( $view, $data, $now ) {
        return _message( $view,
                'The unmodified run passed: '
              . _plural( $data->{tests}, 'test' ) . ', '
              . _plural( $data->{jobs},  'job' ) );
    },
    copy_started => sub ( $view, $data, $now ) {
        $view->{before_copy} = $view->{phase};
        $view->{phase}       = 'copy';
        return _phase( $view, $now );
    },
    copy_finished => sub ( $view, $data, $now ) {
        $view->{phase} = delete $view->{before_copy};
        return _phase( $view, $now );
    },
    mutant   => \&_mutant,
    finished => sub ( $view, $data, $now ) {
        return unless $data->{total};
        $view->@{qw(done total counts)} = ( $data->{total}, $data->{total}, $data->{counts} );
        return _position( $view, $now );
    },
    tick => sub ( $view, $data, $now ) {
        return if $now - $view->{last} < $INTERVAL;
        return $view->{phase} eq 'mutants' && $view->{done} ? _position( $view, $now ) : _phase( $view, $now );
    },
);

signature_for listener =>
  ( positional => [ FileHandle | GlobRef, Bool, Bool, CodeRef, Str, Bool, { default => 0 } ], returns => CodeRef );

sub listener ( $stream, $terminal, $color, $clock, $processors, $defer ) {
    my $started = $clock->();
    my $view    = {
        stream      => $stream,
        terminal    => $terminal,
        color       => $color,
        processors  => $processors,
        started     => $started,
        phase_start => $started,
        phase       => q{},
        last        => $started,
        done        => 0,
        total       => 0,
        tests       => 0,
        tested      => 0,
        counts      => {},
    };
    $view->{pending} = [] if $defer;
    return sub ( $event, $data ) {
        my $handle = $HANDLER{$event} or return;
        if ( $view->{pending}
            && ( $event eq 'baseline' || $event eq 'phase' && $data->{name} =~ /\A(?:baseline|conclude|release)\z/ ) )
        {
            print {$stream} @{ delete $view->{pending} };
        }
        return $handle->( $view, $data, $clock->() );
    };
}

sub _enter ( $view, $data, $now ) {
    $view->{phase}       = $data->{name};
    $view->{phase_start} = $now;
    $view->{validating}  = 1 if $data->{name} eq 'resolve';
    if ( $view->{validating} ) {
        push $view->{waiting}->@*, [ $data->{name}, $now ];
        return;
    }
    return _phase( $view, $now );
}

sub _analyzed ( $view, $data, $now ) {
    delete $view->{validating};
    for my $phase ( @{ delete $view->{waiting} || [] } ) {
        $view->{phase} = $phase->[0];
        _phase( $view, $phase->[1] );
    }
    $view->@{qw(total tests)} = $data->@{qw(mutants tests)};
    _message( $view, $view->{processors} );
    return _message( $view,
            _plural( $data->{mutants}, 'mutant' ) . ' in '
          . _plural( $data->{files}, 'file' ) . ', '
          . _plural( $data->{tests}, 'test' ) );
}

sub _mutant ( $view, $data, $now ) {
    $view->{counts}{ $data->{status} }++;
    $view->{done}++;
    _position( $view, $now )
      if $view->{terminal}
      || Test::Mutation::Report::Progress::due( $view->{done}, $view->{total} )
      || $now - $view->{last} >= $INTERVAL;
    return;
}

sub _plural ( $count, $word ) {
    return $count == 1 ? "$count $word" : "$count " . $word . 's';
}

sub _message ( $view, $text ) {
    if ( $view->{pending} ) {
        push $view->{pending}->@*, "$text\n";
        return;
    }
    print { $view->{stream} } "\n" if delete $view->{open};
    print { $view->{stream} } "$text\n";
    return;
}

sub _phase ( $view, $now ) {
    my $name = ucfirst $view->{phase};
    return unless length $name;
    return if $view->{validating};
    $name = "\e[1m$name\e[0m" if $view->{color};
    my $tests = $view->{phase} eq 'baseline' && $view->{tests} ? " ($view->{tested}/$view->{tests} tests)" : q{};
    _message( $view, "$name$tests | " . int( max( 0, $now - $view->{started} ) ) . 's elapsed' );
    $view->{last} = $now;
    return;
}

sub _position ( $view, $now ) {
    my ( $done, $total ) = $view->@{qw(done total)};
    my $line  = Test::Mutation::Report::Progress::line( $done, $total, $view->{counts} );
    my $final = $done == $total;
    return                      if $final && defined $view->{last_final} && $line eq $view->{last_final};
    $view->{last_final} = $line if $final;
    if ( length $view->{phase} ) {
        $line .= ' | ' . int( max( 0, $now - $view->{started} ) ) . 's elapsed';
        if ( $done && !$final ) {
            my $elapsed   = max( 0, $now - $view->{phase_start} );
            my $remaining = $elapsed / $done * ( $total - $done );
            $line .= ', ' . int($remaining) . 's remaining';
        }
    }
    print { $view->{stream} } "\r" if $view->{terminal};
    print { $view->{stream} } $line;
    $view->{open} = $view->{terminal} && !$final;
    print { $view->{stream} } "\n" unless $view->{open};
    $view->{last} = $now;
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Report::Live - show the current measurement phase and work remaining

=head1 FUNCTIONS

=head2 listener

Takes the output handle, terminal and color flags, a clock in seconds, and the processor description.
An optional flag delays the initial log lines until the input copy has been checked or the measurement ends.
Returns a listener for the measurement events.
The estimate uses the elapsed time per completed mutant in the current phase.
The final position uses the counts from the finished measurement.

=cut
