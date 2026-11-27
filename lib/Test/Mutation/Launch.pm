package Test::Mutation::Launch;
use v5.36;
use Config           qw(%Config);
use File::Spec       ();
use Getopt::Long     ();
use List::Util       qw(uniq);
use Text::ParseWords ();
use Types::Standard  qw(ArrayRef Bool Dict HashRef Int Maybe Optional Str);
use Type::Params     qw(signature_for);
use Test::Mutation::Build;
use Test::Mutation::Error;
use Test::Mutation::Try;

our $VERSION = '0.001';

my $DEFAULTS = Dict [ lib => ArrayRef [Str], switch => ArrayRef [Str] ];
my $SHIM     = Dict [ generation => Int, directory => Str, spec => Str, record => Str ];

signature_for defaults => ( positional => [Str], returns => $DEFAULTS );

sub defaults ($root) {
    my $file      = File::Spec->catfile( $root, '.proverc' );
    my $native    = Test::Mutation::Build::native($root);
    my $libraries = $native->{sources}->@* || $native->{objects}->@* ? [qw(blib/lib blib/arch)] : ['lib'];
    return { lib => $libraries, switch => [] } if !-e $file;
    local %ENV = %ENV;
    require App::Prove;
    my $saved  = Getopt::Long::Configure();
    my $parsed = Test::Mutation::Try::attempt(
        sub {
            Test::Mutation::Try::with_cleanup(
                sub {
                    my $app = App::Prove->new;
                    $app->process_args( '--norc', '--rc', $file );
                    return $app;
                },
                sub { Getopt::Long::Configure($saved) },
            );
        }
    );
    Test::Mutation::Error::raise(
        'input-malformed',
        path   => '.proverc',
        reason => ( split /\n/, "$parsed->{error}" )[0]
    ) if exists $parsed->{error};
    my $app = $parsed->{value};
    Test::Mutation::Error::raise('prove-exec-unsupported') if defined $app->exec;
    my @lib    = ( $app->lib ? 'lib' : (), $app->blib ? qw(blib/lib blib/arch) : (), $app->includes->@* );
    my @switch = (
        $app->taint_fail    ? '-T' : $app->taint_warn    ? '-t' : (),
        $app->warnings_fail ? '-W' : $app->warnings_warn ? '-w' : (),
    );
    return { lib => @lib ? \@lib : $libraries, switch => \@switch };
}

signature_for test_command => (
    named => [
        perl      => Str,
        root      => Str,
        program   => Str,
        tmp       => Str,
        lib       => ArrayRef [Str],
        switch    => ArrayRef [Str],
        first     => Optional [ Maybe [Str] ],
        arguments => ArrayRef [Str],
        { default => sub { [] } },
        shim => Optional [$SHIM],
        env  => HashRef [ Maybe [Str] ],
    ],
    returns => Dict [ command => ArrayRef [Str], env => HashRef [ Maybe [Str] ] ],
);

sub test_command ($arg) {
    state $harness_version = do {
        local %ENV = %ENV;
        require TAP::Harness;
        require TAP::Parser::SourceHandler::Perl;
        TAP::Harness->VERSION;
    };
    my $options = interpreter_options( $arg->root, $arg->lib, $arg->switch );
    my @lib     = $options->{lib}->@*;
    my @switch  = $options->{switch}->@*;
    my $taint   = TAP::Parser::SourceHandler::Perl->get_taint( $arg->first );
    push @switch, "-$taint" if defined $taint && !grep { $_ eq "-$taint" } @switch;
    my $tainted   = grep { /\A-[tT]\z/ } @switch;
    my $separator = $Config{path_sep};
    my $inherited = $arg->env;
    my @prior_lib = grep { defined && length } $inherited->{PERL5LIB};
    my @prior_opt = grep { defined && length } $inherited->{PERL5OPT};
    my %env = ( HARNESS_ACTIVE => 1, HARNESS_VERSION => $harness_version, PWD => $arg->root, TMPDIR => $arg->tmp );
    $env{PERL_DL_NONLAZY} = 1 if grep { m{(?:\A|/)blib/(?:arch|lib)\z} } @lib;
    my ( @extra_lib, @instrument );

    if ( my $shim = $arg->shim ) {
        my $number = $shim->{generation};
        my $dir    = $shim->{directory};
        $env{TEST_MUTATION_GENERATION}        = $number;
        $env{TEST_MUTATION_ROOT}              = $arg->root;
        $env{"TEST_MUTATION_SPEC_G$number"}   = $shim->{spec};
        $env{"TEST_MUTATION_RECORD_G$number"} = $shim->{record};
        push @extra_lib, $dir;
        my $load = "-MTest::Mutation::Shim::G$number";

        # PERL5OPT splits on whitespace even in quotes, and a child may clear PERL5LIB.
        my $include = $dir =~ /\s/ ? '-Mlib+pack(q(H*),q(' . unpack( 'H*', $dir ) . '))' : "-I$dir";
        $env{PERL5OPT} = join q{ }, @prior_opt, $include, $load;
        @instrument    = ( "-I$dir", $load ) if $tainted;
    }
    my @paths    = $tainted ? () : @lib;
    my @portable = grep { index( $_, $separator ) < 0 } @paths;
    my @raw      = ( @portable, @prior_lib, grep { index( $_, $separator ) < 0 } @extra_lib );
    $env{PERL5LIB} = join( $separator, @raw ) if @portable || @extra_lib;
    if ($tainted) {
        push @switch, ( map { "-I$_" } @lib, map { split /\Q$separator\E/ } @prior_lib ),
          ( map { Text::ParseWords::shellwords($_) } @prior_opt ), @instrument;
    }
    else {
        push @switch, map { "-I$_" } grep { index( $_, $separator ) >= 0 } @paths;
    }
    return { command => [ $arg->perl, @switch, $arg->arguments->@*, $arg->program ], env => \%env };
}

signature_for interpreter_options => ( positional => [ Str, ArrayRef [Str], ArrayRef [Str] ], returns => $DEFAULTS );

sub interpreter_options ( $root, $libraries, $switches ) {
    my @lib = @$libraries;
    my @switch;
    my $takes_directory = 0;
    for my $word (@$switches) {
        if ($takes_directory) {
            push @lib, $word;
            $takes_directory = 0;
            next;
        }
        if ( $word eq '-I' ) {
            $takes_directory = 1;
        }
        elsif ( $word =~ /\A-I\s*(.+)\z/s ) {
            push @lib, $1;
        }
        elsif ( $word =~ /\A-Mlib=(.+)\z/s ) {
            push @lib, split /,/, $1;
        }
        else {
            push @switch, $word;
        }
    }
    push @switch, '-I' if $takes_directory;
    return { lib => [ uniq map { File::Spec->rel2abs( $_, $root ) } @lib ], switch => \@switch };
}

1;

__END__

=head1 NAME

Test::Mutation::Launch - construct the Perl command and environment of one task

=head1 FUNCTIONS

=head2 defaults

Reads interpreter options and library directories from the project's F<.proverc>.
An external test executor cannot run an instrumented Perl test.

=head2 interpreter_options

Resolves library directories in the project and separates them from other interpreter options.

=head2 test_command

Returns the argument vector and environment changes for a test or a standalone compilation.
Libraries are resolved in the copy that the process enters.
Tainted processes receive their libraries and inherited switches as arguments.

=cut
