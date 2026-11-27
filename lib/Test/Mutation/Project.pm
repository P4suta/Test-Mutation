package Test::Mutation::Project;
use v5.36;
use File::Find             ();
use Types::Standard        qw(ArrayRef Bool RegexpRef Str);
use Types::Common::Numeric qw(PositiveInt);
use Type::Params           qw(signature_for);
use Test::Mutation::Error;

our $VERSION = '0.001';

my %SKIPPED_AT_ROOT = map { $_ => 1 } qw(local blib _build node_modules);

signature_for pattern_regex => ( positional => [Str], returns => RegexpRef );

sub pattern_regex ($pattern) {
    my $regex = q{};
    my @parts = split m{(\*\*/|\*\*|\*|\?)}, $pattern;
    for my $part (@parts) {
        $regex .=
            $part eq '**/' ? '(?:.*/)?'
          : $part eq '**'  ? '.*'
          : $part eq q{*}  ? '[^/]*'
          : $part eq q{?}  ? '[^/]'
          :                  quotemeta $part;
    }
    return qr/\A$regex\z/;
}

sub _static_directory ($pattern) {
    my ($prefix) = $pattern =~ m{\A([^*?]*)/};
    return defined $prefix ? $prefix : q{};
}

signature_for files => (
    positional => [ Str, ArrayRef [Str], ArrayRef [Str] ],
    returns    => ArrayRef [Str],
);

sub files ( $root, $include, $exclude ) {
    my @excluded = map { pattern_regex($_) } $exclude->@*;
    my %found;
    for my $pattern ( $include->@* ) {
        my $regex     = pattern_regex($pattern);
        my $directory = _static_directory($pattern);
        my $start     = length $directory ? "$root/$directory" : $root;
        next if !-d $start;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    if ( -d $File::Find::name ) {
                        my ($name) = $File::Find::name =~ m{([^/]+)\z};
                        my $hidden = $File::Find::name ne $start && $name =~ /\A[.]/;
                        my $vendor = $File::Find::dir eq $root   && $SKIPPED_AT_ROOT{$name};
                        $File::Find::prune = 1 if $hidden || $vendor;
                        return;
                    }
                    my $relative = substr $File::Find::name, length($root) + 1;
                    return if $relative !~ $regex;
                    return if grep { $relative =~ $_ } @excluded;
                    $found{$relative} = 1;
                },
            },
            $start,
        );
    }
    return [ sort keys %found ];
}

signature_for perl_script => ( positional => [Str], returns => Bool );

sub perl_script ($path) {
    return 0 unless -f $path;
    open my $handle, '<:raw', $path or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    defined sysread( $handle, my $prefix, 4096 )
      or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return 0 if index( $prefix, "\0" ) >= 0;
    $prefix =~ s/\A\xEF\xBB\xBF//;
    my $environment = qr{(?:\S*/)?env [ \t]+ (?:-S [ \t]+)?}x;
    my $perl        = qr{(?:\S*/)?perl(?:5(?:[.][0-9]+)*)? (?:\s|\z)}x;
    my $interpreter = qr{[#]! [ \t]* (?:$environment)? $perl}x;
    return 1 if $prefix =~ /\A$interpreter/;
    return 0 unless $path   =~ /[.]pl\z/;
    return 1 unless $prefix =~ /\A[#]!/;
    my $extract = qr{^[^\n#]* \bperl[ \t]+-x\b [^\n]* \n}mx;
    return $prefix =~ /$extract (?:[^\n]*\n)*? $interpreter/mx ? 1 : 0;
}

signature_for default_jobs => ( positional => [PositiveInt], returns => PositiveInt );

sub default_jobs ($processors) {
    return $processors > 1 ? $processors - 1 : 1;
}

1;

__END__

=head1 NAME

Test::Mutation::Project - find the files of a project

=head1 SYNOPSIS

    my $sources = Test::Mutation::Project::files( $root, ['lib/**/*.pm'], [] );

=head1 FUNCTIONS

=head2 pattern_regex

Compiles a glob pattern to a regular expression that matches a whole relative path.
C<*> matches within one path segment, C<?> matches one character, and C<**> matches across segments.

=head2 files

Returns the sorted relative paths under C<$root> that match an include pattern and no exclude pattern.
Hidden directories are skipped, as are C<local>, C<blib>, C<_build>, and C<node_modules> at the root.

=head2 perl_script

Recognizes a Perl interpreter line, a text F<.pl> file, or a F<.pl> wrapper that invokes C<perl -x>.

=head2 default_jobs

Returns the number of test processes for the given number of processors: one less, and at least one.
L<Test::Mutation::Host> counts the processors that a run may use.

=cut
