use strict;
use warnings;
use Test::More tests => 1;
use ArchiveCount;
is ArchiveCount::entries(qw(alpha beta)), 1, 'the archived assertion expects the earlier catalog size';
