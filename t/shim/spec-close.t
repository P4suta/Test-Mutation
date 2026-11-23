use strict;
use warnings;
use Test::More tests => 2;
use File::Temp ();

# A spec that does not close may be incomplete, so the shim stops the process.
# The override closes the handle and then reports a failure while the flag is set.
our $failing = 0;

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::close = sub (;*) {
        my $closed = @_ ? CORE::close( $_[0] ) : CORE::close();
        return $closed if !$failing;
        $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
}

use Permutl::Shim;

my ( $handle, $path ) = File::Temp::tempfile( UNLINK => 1 );
print {$handle} "trace\t1\n" or die "write: $!";
close $handle                or die "close: $!";

is_deeply Permutl::Shim::read_spec($path), { trace => 1, targets => [] }, 'a spec that closes is read';

$failing = 1;
my $read = eval { Permutl::Shim::read_spec($path) };
$failing = 0;
like $@, qr/\Apermutl: cannot close spec \Q$path\E: \S/, 'a spec that does not close stops the process';
