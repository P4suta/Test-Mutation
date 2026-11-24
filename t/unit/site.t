use v5.36;
use Test2::V0;
use Test::Mutation::Site;

# A mutator reads the facts of a site by name, so a name that the analysis never writes must fail at once.

sub site (%fields) {
    return Test::Mutation::Site->new(
        kind  => 'operator',
        text  => q{+},
        start => 3,
        end   => 4,
        scope => [ 1, 1 ],
        %fields
    );
}

subtest 'a site holds the facts of the analysis' => sub {
    is site()->facts, {}, 'a site without facts';
    is site( facts => { right => 0, version => 5.010, settled => 1 } )->facts,
      { right => 0, version => 5.010, settled => 1 }, 'the facts of a comparison';
    is site( facts => { operand => 'match' } )->facts->{operand}, 'match', 'the operand of a binding operator';
    is site( kind => 'statement', facts => { head => 'close' } )->facts->{head}, 'close',
      'the first word of a statement';
    is site( kind => 'sub_body',  facts => { name    => 'total' } )->facts->{name}, 'total', 'the name of a subroutine';
    is site( kind => 'return',    facts => { literal => '1' } )->facts->{literal},  '1',     'the literal of a return';
    is site( kind => 'condition', facts => { keyword => 'elsif' } )->facts->{keyword}, 'elsif',
      'the keyword of a condition';
};

subtest 'a site refuses a fact outside the shared shape' => sub {
    like dies { site( facts => { rigth   => 0 } ) },     qr/did not pass type constraint/, 'a misspelt name';
    like dies { site( facts => { right   => 'two' } ) }, qr/did not pass type constraint/, 'a number that is a word';
    like dies { site( facts => { operand => 'replace' } ) }, qr/did not pass type constraint/,
      'an unknown kind of operand';
    like dies { site( facts => [ right => 0 ] ) }, qr/did not pass type constraint/, 'a list in place of the facts';
};

done_testing;
