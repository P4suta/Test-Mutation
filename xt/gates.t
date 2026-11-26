use v5.36;
use Test2::V0;
use File::Path ();
use File::Temp ();
use lib 't/lib', 'xt/lib';
use Gate;
use GateFile;
use Library;

# A gate that checks nothing passes for the wrong reason.
# Every gate file therefore states how much it checked, and holds a subtest that feeds it a broken input.

subtest 'the count rejects a gate that checked too little' => sub {
    is Gate::outcomes( sub { Gate::checked( 'files', 3, at_least => 3 ) } ), ['pass'], 'a count at the floor passes';
    is Gate::outcomes( sub { Gate::checked( 'files', 2, at_least => 3 ) } ), ['fail'], 'a count below the floor fails';
    is Gate::outcomes( sub { Gate::checked( 'files', 0, at_least => 1 ) } ), ['fail'], 'an empty scan fails';
    like dies { Gate::checked( 'files', 3 ) }, qr/\Achecked needs a floor/, 'a count without a floor is refused';
};

subtest 'the gate rejects every reported violation' => sub {
    my $outcomes = sub (@found) {
        return Gate::outcomes( sub { Gate::findings( 'symbols', \@found ) } );
    };
    is $outcomes->(),                                                       ['pass'], 'an empty scan result passes';
    is $outcomes->('lib/A.pm documents no x'),                              ['fail'], 'one violation fails';
    is $outcomes->( 'lib/A.pm documents no x', 'lib/B.pm documents no y' ), ['fail'], 'multiple violations fail';
};

subtest 'the meta gate rejects a file without a count or a rejecting subtest' => sub {
    my $complete = <<'PERL';
use Gate;
subtest 'the gate rejects a broken input' => sub { ok 1 };
Gate::checked( 'files', 3, at_least => 1 );
PERL
    is GateFile::violations($complete), [], 'a complete gate file';
    is GateFile::violations("subtest 'the gate rejects a broken input' => sub { ok 1 };\n"), ['states no count'],
      'a file without a count';
    is GateFile::violations("Gate::checked( 'files', 3, at_least => 1 );\n"), ['has no rejecting subtest'],
      'a file without a rejecting subtest';
    is GateFile::violations("# Gate::checked and subtest 'rejects' in a comment\nok 1;\n"),
      [ 'states no count', 'has no rejecting subtest' ], 'a comment states nothing';
    is GateFile::violations("my \$text = q{Gate::checked subtest 'x rejects y'};\n"),
      [ 'states no count', 'has no rejecting subtest' ], 'a string states nothing';
    is GateFile::violations(
        "Gate::checked( 'files', 3, at_least => 1 );\nsubtest 'the gate accepts' => sub { ok 1 };\n"),
      ['has no rejecting subtest'], 'a subtest that rejects nothing';
};

subtest 'the library walk rejects a fixed depth' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    for my $path (qw(A.pm A/B.pm A/B/C/D.pm A/notes.txt)) {
        my ($directory) = "$root/$path" =~ m{\A(.*)/};
        File::Path::make_path($directory);
        open my $handle, '>', "$root/$path" or die "write $path: $!";
        close $handle or die "close $path: $!";
    }
    is Library::modules($root), [ "$root/A.pm", "$root/A/B.pm", "$root/A/B/C/D.pm" ],
      'a module four directories down is found, and another file is left out';
    is Library::package_of( "$root/A/B/C/D.pm", $root ), 'A::B::C::D', 'a path names its package';
};

my @files = Library::tests('xt')->@*;
my @found;
for my $file (@files) {
    open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
    my $code = do { local $/ = undef; readline $handle };
    close $handle or die "close $file: $!";
    push @found, map { "$file $_" } GateFile::violations($code)->@*;
}
Gate::findings( 'gates', \@found );
Gate::checked( 'gate files', scalar @files, at_least => 7 );

done_testing;
