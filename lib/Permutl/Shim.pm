package Permutl::Shim;
use 5.010;
use strict;
use warnings;

our $VERSION = '0.001';

# The driver copies this file under a generation-specific package name and rewrites the next line.
my $GENERATION = 0;

# PERLDB_LINE compiles a dbstate op for every statement.
# PERLDB_NOOPT keeps the first statement of a block, which the compiler otherwise drops.
my $TRACE_FLAGS = 0x02 | 0x04;

my %STATE;

sub spec_variable {
    return $GENERATION ? "PERMUTL_SPEC_G$GENERATION" : 'PERMUTL_SPEC';
}

sub record_variable {
    return $GENERATION ? "PERMUTL_RECORD_G$GENERATION" : 'PERMUTL_RECORD';
}

sub import {
    my $spec_path = $ENV{ spec_variable() };
    return if !defined $spec_path || $STATE{active};
    my $record_dir = $ENV{ record_variable() };
    activate( read_spec($spec_path), $record_dir );
    return;
}

sub read_spec {
    my ($path) = @_;
    open my $handle, '<', $path or die "permutl: cannot read spec $path: $!\n";
    my @lines = <$handle>;
    close $handle or die "permutl: cannot close spec $path: $!\n";
    my %spec = ( trace => 0, targets => [] );
    for my $line (@lines) {
        chomp $line;
        my ( $key, @fields ) = split /\t/, $line, -1;
        next if !defined $key || $key eq q{};
        if ( $key eq 'target' ) {
            push @{ $spec{targets} }, { original => $fields[0], serve => $fields[1] };
        }
        else {
            $spec{$key} = $fields[0];
        }
    }
    return \%spec;
}

sub activate {
    my ( $spec, $record_dir ) = @_;
    return if $STATE{active};

    my %by_base;
    my $index = 0;
    for my $target ( @{ $spec->{targets} } ) {
        $target->{index} = $index++;
        my @stat = stat $target->{original};
        $target->{device} = $stat[0];
        $target->{inode}  = $stat[1];
        $target->{size}   = $stat[7];
        $target->{hits}   = {};
        push @{ $by_base{ _basename( $target->{original} ) } }, $target;
    }

    %STATE = (
        active      => 1,
        trace       => 0,
        debug_flags => $^P,
        targets     => $spec->{targets},
        by_base     => \%by_base,
        by_path     => {},
        record_dir  => _untainted($record_dir),
        pid         => $$,
    );

    my $hook = sub { return _serve(@_) };
    $STATE{hook} = $hook;
    unshift @INC, $hook;
    _keep_hook_first($hook);
    $STATE{trace} = _install_tracer() if $spec->{trace};
    return;
}

sub _basename {
    my ($path) = @_;
    return $path =~ m{([^/]+)\z} ? $1 : $path;
}

sub _untainted {
    my ($value) = @_;
    return if !defined $value;
    my ($clean) = $value =~ /\A(.*)\z/s;
    return $clean;
}

sub _keep_hook_first {
    my ($hook) = @_;
    require lib;
    my $original = \&lib::import;
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    *lib::import = sub {
        my @result = $original->(@_);
        @INC = ( $hook, grep { !( ref $_ && $_ == $hook ) } @INC );    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return @result;
    };
    return;
}

sub _resolve {
    my ($file) = @_;
    for my $entry (@INC) {
        next if ref $entry;
        my $path = "$entry/$file";
        return $path if -f $path;
    }
    return;
}

sub _same_file {
    my ( $path, $target ) = @_;
    my @stat = stat $path or return 0;
    return 1
      if defined $target->{inode}
      && $stat[1] == $target->{inode}
      && $stat[0] == $target->{device};
    return 0 if !defined $target->{size} || $stat[7] != $target->{size};
    return _slurp($path) eq _slurp( $target->{original} );
}

sub _slurp {
    my ($path) = @_;
    open my $handle, '<', $path or return q{};
    binmode $handle;
    local $/ = undef;
    my $content = <$handle>;
    close $handle or return q{};
    return defined $content ? $content : q{};
}

sub _serve {
    my ( undef, $file ) = @_;
    _trace_compile(0) if $STATE{trace};

    my $candidates = $STATE{by_base}{ _basename($file) } or return;
    my $path       = _resolve($file)                     or return;
    my ($target)   = grep { _same_file( $path, $_ ) } @{$candidates};
    return if !$target;

    open my $handle, '<', $target->{serve} or do {    ## no critic (InputOutput::RequireBriefOpen)
        _record( 'error', $target->{original}, "cannot open $target->{serve}: $!" );
        return;
    };
    $target->{served}       = 1;
    $target->{file}         = $file;
    $target->{logical_path} = $path;
    $STATE{by_path}{$path}  = $target;
    _record( 'served', $target->{original} );

    $INC{$file} = $path;                              ## no critic (Variables::RequireLocalizedPunctuationVars)
    my $prepend = sprintf "UNITCHECK { %s::mark_compiled(%d) }\n", __PACKAGE__, $target->{index};
    $prepend .= qq{#line 1 "$path"\n} if $path !~ /["\n]/;
    return ( \$prepend, $handle )     if !$STATE{trace};

    my $filter = sub {
        my $more = length $_ ? 1 : 0;
        _trace_compile($more);
        return $more;
    };
    return ( \$prepend, $handle, $filter );
}

sub mark_compiled {
    my ($index) = @_;
    my $target = $STATE{targets}[$index] or return;
    _record( 'compiled', $target->{original} );
    return;
}

sub _trace_compile {
    my ($enabled) = @_;
    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $^P = $enabled ? $STATE{debug_flags} | $TRACE_FLAGS : $STATE{debug_flags};
    ## use critic
    return;
}

sub _install_tracer {
    _define_dispatcher();
    return 0 if !$Permutl::Shim::DISPATCHER || \&DB::DB != $Permutl::Shim::DISPATCHER;

    my $by_path = $STATE{by_path};
    push @Permutl::Shim::TRACERS, sub {
        my ( $file, $line ) = @_;
        my $target = $by_path->{$file} or return;
        return if $target->{hits}{$line}++;
        _record( 'hit', $target->{original}, $line );
        return;
    };
    $DB::trace = 1;    ## no critic (Variables::ProhibitPackageVars)
    return 1;
}

sub _define_dispatcher {
    return if defined &DB::DB;

    package DB;        ## no critic (Modules::ProhibitMultiplePackages)
    $Permutl::Shim::DISPATCHER = sub {
        my ( undef, $file, $line ) = caller;
        $_->( $file, $line ) for @Permutl::Shim::TRACERS;
        return;
    };
    no strict 'refs';    ## no critic (TestingAndDebugging::ProhibitNoStrict)
    *{'DB::DB'} = $Permutl::Shim::DISPATCHER;
    return;
}

sub _record {
    my (@fields) = @_;
    my $dir = $STATE{record_dir};
    return if !defined $dir;
    if ( !$STATE{record_handle} ) {
        my $name = sprintf '%s/%d-%d-%d.rec', $dir, $STATE{pid}, time, int rand 1_000_000_000;
        open my $handle, '>>', $name or return;    ## no critic (InputOutput::RequireBriefOpen)
        binmode $handle;
        $STATE{record_handle} = $handle;
        syswrite $handle, "begin\t$STATE{trace}\n";
    }
    my @clean = @fields;
    tr/\t\n/  / for @clean;
    syswrite $STATE{record_handle}, join( "\t", @clean ) . "\n";
    return;
}

sub _source_lines {
    my ($path) = @_;
    no strict 'refs';    ## no critic (TestingAndDebugging::ProhibitNoStrict)
    return \@{"main::_<$path"};
}

sub _breakable_lines {
    my ($path) = @_;
    my $lines = _source_lines($path);
    my @breakable;
    for my $number ( 1 .. $#{$lines} ) {
        next if !defined $lines->[$number];
        my $text = "$lines->[$number]";
        no warnings 'numeric';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        my $from_flag   = $lines->[$number] + 0;
        my $from_string = $text + 0;
        push @breakable, $number if $from_flag != $from_string;
    }
    return @breakable;
}

sub _loaded_from_disk {
    my ($target) = @_;
    for my $path ( grep { defined && !ref } values(%INC), $0 ) {
        next if _basename($path) ne _basename( $target->{original} );
        my @stat = stat $path or next;
        return 1 if $stat[1] == $target->{inode} && $stat[0] == $target->{device};
    }
    return 0;
}

sub finish {
    return if !$STATE{active};
    for my $target ( @{ $STATE{targets} } ) {
        if ( !$target->{served} ) {
            _record( 'bypass', $target->{original} )
              if defined $target->{inode} && _loaded_from_disk($target);
            next;
        }
        _record( 'loadfail', $target->{original} ) if !defined $INC{ $target->{file} };
        _record( 'lines', $target->{original}, join q{,}, _breakable_lines( $target->{logical_path} ) )
          if $STATE{trace};
    }
    _record( 'end', $$ );
    return;
}

END {
    my $status = $?;
    finish();
    $? = $status;    ## no critic (Variables::RequireLocalizedPunctuationVars)
}

1;

__END__

=head1 NAME

Permutl::Shim - serve mutated source inside a test process

=head1 DESCRIPTION

The permutl driver loads a copy of this module into every test process.
The copy reads the spec file named by its environment variable and puts a hook at the front of C<@INC>.
When a test requires a target file, the hook serves the replacement source and records the event.
The module depends on core modules alone and runs on Perl 5.10 and later.

=head1 RECORDS

Each process writes tab-separated lines to one file in the record directory.
C<begin> carries 1 when line tracing is active.
C<served>, C<compiled>, C<loadfail>, and C<bypass> carry the original path of a target.
C<hit> carries a target and a line that ran.
C<lines> carries a target and the lines that hold a runtime statement.
C<end> marks a process that reached its C<END> block.

=head1 FUNCTIONS

=head2 import

Activates the shim when the environment names a spec file.
Perl calls it when a C<-M> switch loads the module.

=head2 mark_compiled

Records that the target with the given index compiled.
The text that the hook serves calls it from a C<UNITCHECK> block.

=head2 activate

    Permutl::Shim::activate( $spec, $record_dir );

Installs the hook for the targets in C<$spec>.
C<$spec> has the keys C<targets> and C<trace>.
Each target has the keys C<original> and C<serve>.

=head2 read_spec

    my $spec = Permutl::Shim::read_spec($path);

Parses a tab-separated spec file.

=head2 finish

Writes the load state of every target to the record file.
The C<END> block calls it.

=head2 spec_variable

Returns the name of the environment variable that carries the spec path.

=head2 record_variable

Returns the name of the environment variable that carries the record directory.

=cut
