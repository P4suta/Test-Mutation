use v5.36;
use Test2::V0;
use lib 't/lib';
use Library;
use Test::Mutation::CompilerInputs ();

# Every public subroutine checks its arguments before its body runs.
# The function definitions also describe the public surface when a type declaration is missing.

my @files = grep { $_ ne 'lib/Test/Mutation/Shim.pm' } Library::modules()->@*;
my $count = 0;
my @load_warnings;

for my $file (@files) {
    open my $handle, '<:encoding(UTF-8)', $file or die "read $file: $!";
    my $code = do { local $/ = undef; readline $handle };
    close $handle or die "close $file: $!";

    my $package = Library::package_of($file);
    push @load_warnings, warnings { require $file =~ s{\Alib/}{}r }->@*;

    while ( $code =~ /^sub ([a-z]\w*) \(\s*(\$(?:class|self)\b)?/mg ) {
        my ( $name, $method ) = ( $1, $2 );
        my $subroutine = $package->can($name) or die "$package has no subroutine $name";
        my $wrong      = \my $value;
        my $error      = dies { $method ? $package->$subroutine($wrong) : $subroutine->($wrong) };
        my $typed      = ref $error && $error->isa('Error::TypeTiny');
        ok $typed, "$package\::$name refuses a wrong argument" or diag defined $error ? "$error" : 'the call returned';
        is $error->context->{file}, __FILE__, "$package\::$name identifies the call that supplied the invalid argument"
          if $typed;
        $count++;
    }
}

ok $count >= 50, "the public functions reject invalid arguments ($count)";
is \@load_warnings, [], 'the contract check loads every driver module without warnings';

done_testing;
