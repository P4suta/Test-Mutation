use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use POSIX      ();
use lib 't/e2e/lib';
use Fixture qw(copy_of write_file);
use Test::Mutation;
use Test::Mutation::Outcome;

sub verdicts ($result) {
    return [ map { [ $_->{mutant}->id, $_->@{qw(status reason detail by covered_by)} ] } $result->entries->@* ];
}

for my $change ( 0, 1 ) {
    my $root = copy_of('equivalent');
    local $ENV{TMPDIR} = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my %options = ( root => $root, jobs => 1 );
    my $driver  = fork;
    die "fork: $!" unless defined $driver;
    if ( !$driver ) {
        Test::Mutation::run(
            %options,
            on_event => sub ( $event, $data ) {
                POSIX::_exit(77) if $event eq 'mutant' && $data->{status} eq 'Killed';
            },
        );
        POSIX::_exit(78);
    }
    waitpid $driver, 0;
    is $? >> 8, 77, 'the driver exited at its first detected change without running cleanup';
    write_file( "$root/t/fold.t", "use Test::More tests => 1;\nuse Fold;\npass 'loaded';\n" ) if $change;
    my $resumed   = Test::Mutation::run(%options);
    my $reference = Test::Mutation::run( %options, jobs => 2, cache => 0 );
    is $resumed->reused,   $change ? 0 : 1,      'resume uses the completed observation only while its inputs match';
    is verdicts($resumed), verdicts($reference), 'the returned verdicts agree with a fresh parallel measurement';
    is $resumed->tally,    $reference->tally,    'the resumed measurement has the full score';
    is Test::Mutation::Outcome::of( $resumed, 70 )->{exit}->code,
      Test::Mutation::Outcome::of( $reference, 70 )->{exit}->code, 'the resumed threshold decision matches';
    is [ glob "$ENV{TMPDIR}/mutation-*" ], [], 'the next run reclaimed the abandoned workspace';
}

done_testing;
