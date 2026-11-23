use v5.36;
use Test2::V0;
use File::Path ();
use File::Temp ();
use Permutl::Runner;

# The run copies the source of the shim from the first entry of @INC that supplies it.
# An entry is a directory or a hook, and an outer run of permutl serves the file through its own hook.

my $SHIM  = "package Permutl::Shim;\nmy \$GENERATION = 0;\n1;\n";
my $THIRD = "package Permutl::Shim::G3;\nmy \$GENERATION = 3;\n1;\n";

sub handle_of ($text) {
    open my $handle, '<', \$text or die "open: $!";
    return $handle;
}

sub directory_with ($text) {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    File::Path::make_path("$directory/Permutl");
    open my $handle, '>', "$directory/Permutl/Shim.pm" or die "write: $!";
    print {$handle} $text or die "write: $!";
    close $handle         or die "close: $!";
    return $directory;
}

# A test function may load a module on its first use, so the changed search path lasts for the one call.
# A hook of the tests answers for the shim alone, as the hook of an outer run answers for its targets alone.
sub shim_through (@entries) {
    local @INC = @entries;
    my $text = eval { Permutl::Runner::shim_text(3) };
    return defined $text ? $text : "died: $@";
}

sub hook ($answer) {
    return sub ( $self, $file ) { return $file eq 'Permutl/Shim.pm' ? $answer->() : () };
}

subtest 'the shim of the distribution is renamed for its generation' => sub {
    my $text = Permutl::Runner::shim_text(3);
    like $text,   qr/^package Permutl::Shim::G3;$/m, 'the package carries the generation';
    like $text,   qr/^my \$GENERATION = 3;$/m,       'the generation number is set';
    unlike $text, qr/^package Permutl::Shim;$/m,     'the original package line is gone';
};

subtest 'a directory supplies the text, and the text gets the generation' => sub {
    is shim_through( directory_with($SHIM), @INC ), $THIRD, 'the package and the generation carry the number';
};

subtest 'entries without the file are passed over' => sub {
    my @asked;
    my $text = shim_through(
        sub ( $self, $file ) { push @asked, $file; return },
        [ sub { die "an array entry is no source for the run\n" } ],
        hook(
            sub {
                return sub { return 0 }
            }
        ),
        File::Temp::tempdir( CLEANUP => 1 ),
        directory_with($SHIM),
        @INC,
    );
    is $text,   $THIRD,              'the text comes from the first directory that has the file';
    is \@asked, ['Permutl/Shim.pm'], 'a hook is asked for the file by its name';
};

subtest 'a hook supplies the text through a file handle' => sub {
    my $before = "a line that perl would compile first\n";
    is shim_through( hook( sub { return ( \$before, handle_of($SHIM) ) } ), @INC ), $THIRD,
      'the text of the handle, without the text that comes before it';

    my @seen;
    my $filter = sub { push @seen, $_; return length $_ ? 1 : 0 };
    is shim_through( hook( sub { return ( handle_of($SHIM), $filter ) } ), @INC ), $THIRD,
      'the text of a handle with a filter';
    is \@seen, [ ( split /^/, $SHIM ), q{} ], 'the filter gets each line and then the end, as it does when perl reads';
};

subtest 'a missing file and an unexpected text stop the run' => sub {
    is shim_through( sub { return } ), "died: cannot find Permutl/Shim.pm\n", 'no entry has the file';
    for my $text ( "package Permutl::Shim;\n1;\n", "package Other;\nmy \$GENERATION = 0;\n1;\n" ) {
        is shim_through( directory_with($text), @INC ), "died: cannot prepare the shim for generation 3\n",
          'a text without ' . ( $text =~ /GENERATION/ ? 'the package line' : 'the generation line' );
    }
};

done_testing;
