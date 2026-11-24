use v5.36;
use Test2::V0;
use lib 't/lib';
use Library;

# Every public subroutine checks its arguments before its body runs.
# A lone scalar reference fits no declared signature, so each call must end in a type error.

my @files = grep { $_ ne 'lib/Test/Mutation/Shim.pm' } Library::modules()->@*;
my $count = 0;

for my $file (@files) {
    open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
    my $code = do { local $/ = undef; readline $handle };
    close $handle or die "close $file: $!";

    my $package = $file =~ s{\Alib/}{}r =~ s{[.]pm\z}{}r =~ s{/}{::}gr;
    require $file =~ s{\Alib/}{}r;

    while ( $code =~ /^signature_for (\w+) => (.*?)^sub \1\b/msg ) {
        my ( $name, $declaration ) = ( $1, $2 );
        my $subroutine = $package->can($name) or die "$package has no subroutine $name";
        my $wrong      = \my $value;
        my $error =
          dies { $declaration =~ /\bmethod\s*=>\s*1/ ? $package->$subroutine($wrong) : $subroutine->($wrong) };
        ok ref $error && $error->isa('Error::TypeTiny'), "$package\::$name refuses a wrong argument"
          or diag defined $error ? "$error" : 'the call returned';
        $count++;
    }
}

ok $count >= 50, "the files declare signatures ($count)";

done_testing;
