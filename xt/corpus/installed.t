use v5.36;
use Test2::V0;
use File::Find ();
use POSIX      ();
use Test::Mutation::Mutant::Generator;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Project;
use Test::Mutation::Source;
use Test::Mutation::Syntax::PPI;

# The installed dependencies are a corpus of real code that nobody wrote with this tool in mind.
# Every file must analyze without an exception, and every site and mutant must address its own text.

my @files;
File::Find::find( { no_chdir => 1, wanted => sub { push @files, $File::Find::name if /[.]pm\z/ && -f } },
    'local/lib/perl5' );
@files = sort @files;
ok scalar(@files) > 500, 'the corpus holds the installed modules (' . scalar(@files) . ')';

sub findings ($path) {
    open my $handle, '<:raw', $path or return "cannot read: $!";
    my $bytes  = do { local $/ = undef; readline $handle };
    my $source = eval { Test::Mutation::Source->from_bytes( path => $path, bytes => $bytes ) } or return 'undecodable';
    my $text   = $source->text;
    my ( @found, $mutants );
    my $analysis = eval { Test::Mutation::Syntax::PPI::analyze($source) } or return "analysis died: $@";
    return "problem: $analysis->{problem}" if defined $analysis->{problem};

    for my $site ( $analysis->{sites}->@* ) {
        push @found, 'site ' . $site->start . ' does not address its text'
          if substr( $text, $site->start, $site->end - $site->start ) ne $site->text;
    }
    my $generated = eval {
        $mutants = Test::Mutation::Mutant::Generator::generate(
            source   => $source,
            analysis => $analysis,
            mutators => Test::Mutation::Mutator::Catalog::mutators(),
        );
        1;
    };
    return "generation died: $@" if !$generated;
    for my $mutant ( $mutants->{mutants}->@* ) {
        my $mutated = $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement );
        push @found, 'mutant ' . $mutant->id . ' leaves the text as it was' if $mutated eq $text;
        push @found, 'mutant ' . $mutant->id . ' does not replace its own text'
          if substr( $text, $mutant->start, $mutant->end - $mutant->start ) ne $mutant->original;
    }
    return ( @found, sprintf 'counted %d %d', scalar $analysis->{sites}->@*, scalar $mutants->{mutants}->@* );
}

my $workers = Test::Mutation::Project::cpu_count();
my @readers;
for my $worker ( 0 .. $workers - 1 ) {
    pipe my $read, my $write or die "pipe: $!";
    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        close $read;
        for my $index ( grep { $_ % $workers == $worker } 0 .. $#files ) {
            print {$write} map { "$files[$index]\t" . s/\s+/ /gr . "\n" } findings( $files[$index] );
        }
        close $write;
        POSIX::_exit(0);
    }
    close $write;
    push @readers, [ $pid, $read ];
}

my ( %problem, @broken, $analyzed, $sites, $mutants );
for my $reader (@readers) {
    my ( $pid, $read ) = $reader->@*;
    while ( my $line = readline $read ) {
        chomp $line;
        my ( $path, $finding ) = split /\t/, $line, 2;
        if ( $finding =~ /\Acounted (\d+) (\d+)\z/ ) {
            $analyzed++;
            $sites   += $1;
            $mutants += $2;
        }
        elsif ( $finding =~ /\A(?:undecodable|problem: (.*))\z/ ) {
            push $problem{ ( $1 // 'undecodable' ) =~ s/:.*//sr }->@*, $path;
        }
        else {
            push @broken, "$path: $finding";
        }
    }
    waitpid $pid, 0;
    is $?, 0, "worker $pid ended cleanly";
}

is \@broken, [], 'no file breaks the analysis, a site, or a mutant';
my %known = map { $_ => 1 } 'the file has carriage returns', 'PPI cannot parse the file',
  'PPI does not reproduce the file',
  'undecodable';
is [ grep { !$known{$_} } sort keys %problem ], [], 'every skipped file names a known reason';
note sprintf '%d files analyzed, %d sites, %d mutants', $analyzed, $sites, $mutants;
note sprintf '%d files skipped: %s', scalar $problem{$_}->@*, $_ for sort keys %problem;
ok $analyzed > 0.95 * @files, 'at least 95 percent of the corpus is analyzed';

done_testing;
