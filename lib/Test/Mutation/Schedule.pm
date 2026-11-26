package Test::Mutation::Schedule;
use v5.36;
use File::Spec             ();
use TAP::Harness           ();
use TAP::Parser::Scheduler ();
use Types::Standard        qw(ArrayRef Bool InstanceOf Maybe Str);
use Type::Params           qw(signature_for);
use Type::Tiny             ();
use Test::Mutation::Error;
use Test::Mutation::Try;

our $VERSION = '0.001';

my $RULE  = Type::Tiny->new( name => 'HarnessRule', constraint => sub { _valid_rule( $_, {} ) } );
my $RULES = Maybe [$RULE];

sub _valid_rule ( $node, $ancestors ) {
    return 0 unless ref $node eq 'HASH' && keys %$node == 1;
    my ($mode) = keys %$node;
    return 0 unless $mode eq 'par' || $mode eq 'seq';
    return 0 if $ancestors->{$node};
    local $ancestors->{$node} = 1;
    my $patterns = $node->{$mode};
    return 1 if defined $patterns && !ref $patterns;
    return 0 unless ref $patterns eq 'ARRAY';
    return !grep { !defined || ref && !_valid_rule( $_, $ancestors ) } @$patterns;
}

signature_for rules => ( positional => [Str], returns => $RULES );

sub rules ($root) {
    my @files = defined $ENV{HARNESS_RULESFILE} ? ( $ENV{HARNESS_RULESFILE} ) : qw(testrules.yml t/testrules.yml);
    my ($file) = grep { -r $_ } map { File::Spec->rel2abs( $_, $root ) } grep { length } @files;
    return unless defined $file;
    my $read = Test::Mutation::Try::attempt(
        sub {
            my $rules = TAP::Harness->new( { rulesfile => $file } )->rules;
            $RULE->assert_valid($rules);
            TAP::Parser::Scheduler->new( rules => $rules, tests => [] );
            return $rules;
        }
    );
    Test::Mutation::Error::raise( 'input-malformed', path => $file, reason => ( split /\n/, "$read->{error}" )[0] )
      if exists $read->{error};
    return $read->{value};
}

signature_for queue => (
    positional => [ $RULES, ArrayRef [Str] ],
    returns    => InstanceOf ['TAP::Parser::Scheduler'],
);

sub queue ( $rules, $tests ) {
    return TAP::Parser::Scheduler->new( tests => $tests, rules => $rules );
}

signature_for compatible => ( positional => [ $RULE, Str, Str ], returns => Bool );

sub compatible ( $rules, $running, $candidate ) {
    my $queue = queue( $rules, [ $running, $candidate ] );
    $queue->get_job;
    return $queue->get_job->is_spinner ? 0 : 1;
}

1;

__END__

=head1 NAME

Test::Mutation::Schedule - apply harness rules to baseline and mutant tests

=head1 FUNCTIONS

=head2 rules

Reads the distribution's rules with the same precedence and parser as C<prove>.

=head2 queue

Returns the harness scheduler for the selected tests.

=head2 compatible

Reports whether two invocations can run at the same time under the project's rules.

=cut
