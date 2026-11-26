package CompileDuringLoad;
use strict;
use warnings;

BEGIN {
    eval { require Scalar::Util; 1 } or die "load probe failed: $@";
}

sub available { return 1 }

1;
