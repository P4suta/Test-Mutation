use strict;
use warnings;
use Fcntl qw(LOCK_EX LOCK_NB);
use File::Temp ();
use Test::More tests => 1;

my $resource = $ENV{MUTATION_TEST_LOCK} || File::Temp->new;
my $generation = $ENV{TEST_MUTATION_GENERATION};
my $spec = defined $generation ? $ENV{"TEST_MUTATION_SPEC_G$generation"} || '' : '';
my ($mutant) = $spec =~ m{/mutants/([0-9a-f]+)[.]spec\z};
my ($phase) = $spec =~ m{/(baseline|separate)(?:-[0-9]+)?[.]spec\z};
$phase = 'mutants' if defined $mutant;
my $skip = $ENV{MUTATION_TEST_SKIP_RETRY} && defined $mutant ? "$resource.$mutant" : undef;

sub mark {
    open my $flag, '>', $_[0] or die "open $_[0]: $!";
    close $flag or die "close $_[0]: $!";
}

if (defined $skip && -e $skip) {
    pass 'the isolated retry does not load the target';
} else {
    require Exclusive;
    Exclusive::number(2);
    open my $lock, '>>', $resource or die "open $resource: $!";
    my $free = flock($lock, LOCK_EX | LOCK_NB);
    my $wanted = $ENV{MUTATION_TEST_OVERLAP} || '';
    if (defined $phase && ($wanted eq $phase || $wanted eq 'originals' && $phase ne 'mutants')) {
        my $peer = "$resource.$phase";
        if ($free) {
            local $SIG{ALRM} = sub { die "no contender reached $phase\n" };
            alarm 20;
            select undef, undef, undef, 0.01 until -e $peer;
            alarm 0;
        } else {
            mark($skip) if defined $skip;
            mark($peer);
        }
    }
    ok $free, 'holds the resource';
}
