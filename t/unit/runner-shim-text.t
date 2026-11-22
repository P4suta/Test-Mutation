use v5.36;
use Test2::V0;
use Permutl::Runner;

subtest 'the shim is renamed for its generation' => sub {
    my $text = Permutl::Runner::shim_text(3);
    like $text,   qr/^package Permutl::Shim::G3;$/m, 'the package carries the generation';
    like $text,   qr/^my \$GENERATION = 3;$/m,       'the generation number is set';
    unlike $text, qr/^package Permutl::Shim;$/m,     'the original package line is gone';
};

subtest 'a hook in the module search path supplies the source' => sub {
    my $served = "package Permutl::Shim;\nmy \$GENERATION = 0;\n# served by a hook\n1;\n";
    my @filtered;
    local @INC = (
        sub ( $self, $file ) {
            return if $file ne 'Permutl/Shim.pm';
            open my $handle, '<', \$served or die "open: $!";
            my $prepend = "UNITCHECK { Outer::mark(0) }\n#line 1 \"lib/Permutl/Shim.pm\"\n";
            return ( \$prepend, $handle, sub { push @filtered, $_; return length $_ ? 1 : 0 } );
        },
        @INC,
    );
    my $text = Permutl::Runner::shim_text(2);
    like $text,   qr/^# served by a hook$/m,         'the text comes from the hook';
    like $text,   qr/^package Permutl::Shim::G2;$/m, 'and is renamed';
    unlike $text, qr/UNITCHECK|Outer::mark/,         'the text that the hook prepends for the compiler is left out';
    is \@filtered, [ "package Permutl::Shim;\n", "my \$GENERATION = 0;\n", "# served by a hook\n", "1;\n", q{} ],
      'the line filter of the hook sees every line and the end of the file';
};

subtest 'a source that cannot be renamed is refused' => sub {
    my $served = "package Something::Else;\n1;\n";
    local @INC = (
        sub ( $self, $file ) {
            return if $file ne 'Permutl/Shim.pm';
            open my $handle, '<', \$served or die "open: $!";
            return $handle;
        },
    );
    like dies { Permutl::Runner::shim_text(1) }, qr/cannot prepare the shim for generation 1/, 'refused';
};

done_testing;
