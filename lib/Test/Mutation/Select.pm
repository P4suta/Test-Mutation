package Test::Mutation::Select;
use v5.36;
use Cwd             ();
use File::Spec      ();
use Types::Standard qw(ArrayRef Bool InstanceOf Maybe Optional Str Undef);
use Type::Params    qw(signature_for);
use Digest::SHA     ();
use File::Basename  ();
use POSIX           ();
use Test::Mutation::Diff;
use Test::Mutation::Git;
use Test::Mutation::Mutant::Generator;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Project;
use Test::Mutation::Selection;
use Test::Mutation::Signals;
use Test::Mutation::Source;
use Test::Mutation::Suppression;
use Test::Mutation::Syntax::PPI;
use Test::Mutation::Error;
use Test::Mutation::Types qw(PathSelection);

our $VERSION = '0.001';

sub _refuse ( $path, $reason ) {
    return Test::Mutation::Error::raise( 'path-selector-invalid', path => $path, reason => $reason );
}

sub _ranges ( $operand, $lines ) {
    my @ranges;
    for my $part ( split /,/, $lines, -1 ) {
        my ( $first, $last ) = $part =~ /\A([1-9][0-9]*)(?:-([1-9][0-9]*))?\z/;
        _refuse( $operand, 'expected a positive line or ascending line range' ) if !defined $first;
        $last = $first                                                          if !defined $last;
        _refuse( $operand, 'the last line precedes the first' )                 if $last < $first;
        push @ranges, [ 0 + $first, 0 + $last ];
    }
    return \@ranges;
}

signature_for paths => ( positional => [ Str, ArrayRef [Str], ArrayRef [Str] ], returns => PathSelection );

sub paths ( $root, $operands, $sources ) {
    my %selected;
    for my $operand ( $operands->@* ) {
        my ( $path, $lines ) = ($operand);
        ( $path, $lines ) = ( $1, $2 ) if !-e File::Spec->rel2abs( $path, $root ) && $operand =~ /\A(.+):([^:]*)\z/;
        my $absolute = File::Spec->rel2abs( $path, $root );
        _refuse( $operand, 'the path does not exist' ) if !length $path || !-e $absolute;
        my $relative  = File::Spec->abs2rel( Cwd::abs_path($absolute), $root );
        my $directory = -d $absolute;
        _refuse( $operand, 'a line range needs a file' ) if defined $lines && ( $directory || !length $lines );
        my $ranges = defined $lines ? _ranges( $operand, $lines ) : [];
        my @matches =
          grep { $_ eq $relative || ( $directory && ( $relative eq q{.} || index( $_, "$relative/" ) == 0 ) ) }
          $sources->@*;
        _refuse( $operand, 'no selected source matches the path' ) if !@matches;

        for my $file (@matches) {
            next                  if exists $selected{$file} && !$selected{$file}->@*;
            $selected{$file} = [] if !$ranges->@*;
            push $selected{$file}->@*, $ranges->@* if $ranges->@*;
        }
    }
    return \%selected;
}

signature_for resolve => (
    named => [
        config   => InstanceOf ['Test::Mutation::Config'],
        paths    => Optional [ Maybe [PathSelection] ],
        operands => ArrayRef [Str],
        { default => sub { [] } },
        baseline_only => Bool,
        { default => 0 },
        reports => Bool,
        { default => 0 },
        summary => Optional [ Maybe [Str] ],
    ],
    returns => InstanceOf ['Test::Mutation::Selection'],
);

sub resolve ($arg) {
    my $config = $arg->config;
    my $root   = $config->root;
    Test::Mutation::Error::raise(
        'directory-closed',
        directory => $root,
        reason    => 'expected an accessible directory'
    ) if !-d $root || !-x $root;
    $root = Cwd::abs_path($root);
    my $mutators = Test::Mutation::Mutator::Catalog::choose(
        profile => $config->profile,
        enable  => $config->enable,
        disable => $config->disable
    );
    my ( $program, $version ) = _interpreter( $root, $config->perl );
    my %matches;
    my $files    = _files( $config, $root, 'source', \%matches );
    my $tests    = _files( $config, $root, 'test',   \%matches );
    my $changed  = defined $config->since ? Test::Mutation::Git::changed( $root, $config->since ) : undef;
    my $paths    = $arg->operands->@*     ? paths( $root, $arg->operands, $files )                : $arg->paths;
    my $analysis = _analysis(
        $config, $files,
        $mutators,
        {
            root          => $root,
            version       => $version,
            paths         => $paths,
            changed       => $changed,
            baseline_only => $arg->baseline_only
        }
    );
    my @mutants = $analysis->{mutants}->@*;

    if ( $config->mutant->@* ) {
        my %wanted;
        for my $prefix ( $config->mutant->@* ) {
            Test::Mutation::Error::raise( 'mutant-unknown', identifier => $prefix ) if length($prefix) < 4;
            my $id = by_id( \@mutants, $prefix )->id;
            $wanted{$id} = 1;
            $matches{mutant}{$prefix} = [$id];
        }
        @mutants = grep { $wanted{ $_->id } } @mutants;
    }
    my $inventory =
      { mutants => scalar @mutants, digest => Digest::SHA::sha256_hex( join "\n", map { $_->id } @mutants ) };
    if ( defined $config->shard ) {
        my ( $part, $parts ) = split m{/}, $config->shard;
        @mutants = @mutants[ grep { $_ % $parts == $part - 1 } 0 .. $#mutants ];
    }
    outputs( $config, $arg->summary ) if $arg->reports;
    return Test::Mutation::Selection->new(
        $analysis->%*,
        project   => $root,
        perl      => $program,
        tests     => $tests,
        mutators  => $mutators,
        mutants   => \@mutants,
        inventory => $inventory,
        matches   => \%matches,
        narrowed  => (
            $paths
              || grep { exists $config->specified->{$_} }
              qw(source source-exclude test test-exclude since mutant enable disable profile shard)
        ) ? 1 : 0,
    );
}

sub _files ( $config, $root, $name, $matches ) {
    my $exclude = $name . '_exclude';
    my %found;
    for my $item ( [ $name, $config->$name ], [ "$name-exclude", $config->$exclude ] ) {
        my ( $setting, $patterns ) = $item->@*;
        for my $pattern ( $patterns->@* ) {
            my $paths;
            if ( $setting eq $name ) {
                $paths = Test::Mutation::Project::files( $root, [$pattern], [] );
            }
            else {
                my $exclude_pattern = Test::Mutation::Project::pattern_regex($pattern);
                $paths = [ sort grep { /$exclude_pattern/ } keys %found ];
            }
            if ( exists $config->specified->{$setting} ) {
                Test::Mutation::Error::raise(
                    'glob-unmatched',
                    setting => $config->specified->{$setting},
                    pattern => $pattern
                ) if !$paths->@*;
                $matches->{$setting}{$pattern} = $paths;
            }
            if ( $setting eq $name ) {
                @found{ $paths->@* } = (1) x $paths->@*;
            }
            else {
                delete @found{ $paths->@* };
            }
        }
    }
    return [ sort keys %found ];
}

sub _interpreter ( $root, $name ) {
    my @candidates =
      $name =~ m{/}
      ? ( File::Spec->rel2abs( $name, $root ) )
      : map { File::Spec->rel2abs( File::Spec->catfile( $_, $name ), $root ) } File::Spec->path;
    my ($program) = grep { -f $_ && -x _ } @candidates;
    Test::Mutation::Error::raise( 'interpreter-invalid', program => $name ) if !defined $program;
    return ( $program, 0 + $] )                                             if $program eq $^X;
    my $pid = open my $answer, q{-|};
    Test::Mutation::Error::raise( 'interpreter-invalid', program => $name ) if !defined $pid;
    _print_version($program)                                                if !$pid;
    my $version = join q{}, readline $answer;
    my $ok      = close $answer;
    Test::Mutation::Error::raise( 'interpreter-invalid', program => $name )
      if !$ok || $version !~ /\A[0-9]+(?:[.][0-9]+)?\z/ || $version < 5.010;
    return ( $program, 0 + $version );
}

sub _print_version ($program) {
    delete $ENV{PERL5OPT};
    open STDERR, '>', File::Spec->devnull or POSIX::_exit(126);
    no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    exec {$program} $program, '-e', 'print $]';
    return POSIX::_exit(127);
}

signature_for by_id => (
    positional => [ ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ], Str ],
    returns    => InstanceOf ['Test::Mutation::Mutant']
);

sub by_id ( $mutants, $prefix ) {
    my @matches = length $prefix ? grep { index( $_->id, $prefix ) == 0 } $mutants->@* : ();
    Test::Mutation::Error::raise( 'mutant-unknown',   identifier => $prefix ) if !@matches;
    Test::Mutation::Error::raise( 'mutant-ambiguous', identifier => $prefix ) if @matches > 1;
    return $matches[0];
}

signature_for outputs => ( positional => [ InstanceOf ['Test::Mutation::Config'], Maybe [Str] ], returns => Undef );

sub outputs ( $config, $summary ) {
    my %wanted = map { $_ => 1 } $config->format->@*;
    if ( $wanted{json} || $wanted{html} ) {
        my $directory = File::Spec->rel2abs( $config->report_dir, $config->root );
        my $parent    = $directory;
        $parent = File::Basename::dirname($parent) while !lstat $parent;
        Test::Mutation::Error::raise(
            'directory-uncreatable',
            path   => $config->report_dir,
            reason => 'expected a writable directory'
        ) if !-d $parent || !-w _ || !-x _;
        for my $format ( grep { $wanted{$_} } qw(json html) ) {
            my $target = "$directory/mutation.$format";
            _writable_file($target) if -e $target || -l $target;
        }
    }
    if ( $wanted{github} && defined $summary && length $summary ) {
        my $path = File::Spec->rel2abs( $summary, $config->root );
        _writable_file($path);
    }
    return;
}

sub _writable_file ($path) {
    my $parent = File::Basename::dirname($path);
    my $ok     = -e $path || -l $path ? -f $path && -w _ : -d $parent && -x _ && -w _;
    Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => 'expected a writable file' ) if !$ok;
    return;
}

sub _analysis ( $config, $files, $mutators, $options ) {
    my ( $root, $paths, $changed ) = $options->@{qw(root paths changed)};
    my %chosen = map { $_->name => 1 } $mutators->@*;
    my $others = [ grep { !$chosen{ $_->name } } Test::Mutation::Mutator::Catalog::mutators()->@* ];
    my ( %sources, %digests, %left_out, @mutants, @problems, @rejected, @refusals );
    for my $path ( $files->@* ) {
        next if $changed && !$changed->{$path};
        next if $paths   && !exists $paths->{$path};
        my $bytes  = Test::Mutation::Source::read_bytes("$root/$path");
        my $source = Test::Mutation::Source->from_bytes( path => $path, bytes => $bytes );
        $digests{$path} = Digest::SHA::sha256_hex($bytes);
        if ( $options->{baseline_only} ) {
            $sources{$path} = $source;
            next;
        }
        my $analysis = Test::Mutation::Syntax::PPI::analyze($source);

        # The analysis of a file is the longest step outside the tests, so a signal ends the work after the file it met.
        Test::Mutation::Signals::check();
        if ( defined $analysis->{problem} ) {
            push @problems, { path => $path, problem => $analysis->{problem} };
            next;
        }
        $sources{$path}  = $source;
        $left_out{$path} = scalar $analysis->{dropped}->@* if $analysis->{dropped}->@*;
        my $generated = Test::Mutation::Mutant::Generator::generate(
            source   => $source,
            analysis => $analysis,
            mutators => $mutators,
            perl     => $options->{version}
        );
        my $judged = Test::Mutation::Mutant::Generator::generate(
            source   => $source,
            analysis => $analysis,
            mutators => $others,
            perl     => $options->{version}
        );
        push @refusals,
          Test::Mutation::Suppression::refusals(
            path           => $path,
            suppression    => $analysis->{suppressions},
            mutants        => [ map { $_->{mutants}->@* } $generated, $judged ],
            require_names  => $config->suppress_require_names,
            require_reason => $config->suppress_require_reason,
          )->@*;
        push @mutants, grep { !$paths || !$paths->{$path}->@* || _in_changed_lines( $paths->{$path}, $_ ) }
          grep { !$changed || _in_changed_lines( $changed->{$path}, $_ ) } $generated->{mutants}->@*;
        push @rejected, map { { path => $path, $_->%* } } $generated->{rejected}->@*;
    }

    # A run with a broken comment would measure other mutants than the comments ask for, so it measures none.
    Test::Mutation::Error::raise( 'suppressions-invalid', list => join q{; }, map { $_->{text} } @refusals )
      if @refusals;
    return {
        sources    => \%sources,
        mutants    => \@mutants,
        unanalyzed => \@problems,
        rejected   => \@rejected,
        left_out   => \%left_out,
        digests    => \%digests
    };
}

sub _in_changed_lines ( $ranges, $mutant ) {
    my ( $first, $last ) = ( $mutant->from->[0], $mutant->to->[0] );

    # An end at the first column of a line leaves that line outside the mutant.
    $last-- if $mutant->to->[1] == 1;
    return Test::Mutation::Diff::touches( $ranges, $first, $last );
}

1;

__END__

=head1 NAME

Test::Mutation::Select - resolve source path and line operands against a project

=head1 SYNOPSIS

    my $paths = Test::Mutation::Select::paths( $root, ['lib/Adder.pm:7,10-12'], $sources );

=head1 FUNCTIONS

=head2 resolve

Resolves the configured globs, changed lines, path operands, suppressions, mutant prefixes, and shard in order.
Returns a L<Test::Mutation::Selection> before the runner acquires a workspace.

=head2 by_id

Returns the single mutant matching the supplied identifier prefix.

=head2 outputs

Checks the files requested by the selected report formats and the GitHub step summary.

=head2 paths

Returns the selected source paths and their inclusive line ranges.
An empty list for a selected file covers every line.
Directory operands include all matching sources below them.
An invalid operand raises a usage error before the run starts.

=cut
