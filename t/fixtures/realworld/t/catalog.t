use strict;
use warnings;
use Test::More tests => 2;
use ArchiveCount;
is ArchiveCount::entries(qw(alpha beta)), 2, 'the current archive contains both entries';
is ArchiveCount::entries(), 0, 'an empty archive contains no entries';
