use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib', 't/e2e/lib';
use Fixture ();
use Gate;
use Test::Mutation;
use Test::Mutation::Mutant;
use Test::Mutation::Settings;
use Test::Mutation::Suppression;

# The grammar of the suppression comments, read from the facts of each comment that the analysis of a file gives.

my $PATH = 'lib/A.pm';

sub comment ( $line, $text, %fact ) {
    return { line => $line, own => 0, text => $text, routine => undef, %fact };
}

sub own ( $line, $text, %fact ) {
    return comment( $line, $text, own => 1, %fact );
}

sub parsed (@comments) {
    return Test::Mutation::Suppression::parse( path => $PATH, comments => \@comments );
}

sub ranges (@comments) {
    return [ map { [ $_->@{qw(line first last)}, $_->{names}, $_->{reason} ] } parsed(@comments)->{directives}->@* ];
}

sub refused (@comments) {
    return [ map { [ $_->@{qw(line id)} ] } parsed(@comments)->{refusals}->@* ];
}

sub mutant ( $line, $mutator ) {
    return Test::Mutation::Mutant->new(
        id          => sprintf( '%012x', $line ),
        path        => $PATH,
        mutator     => $mutator,
        start       => 0,
        end         => 1,
        original    => q{+},
        replacement => q{-},
        description => 'replaced + with -',
        from        => [ $line, 9 ],
        to          => [ $line, 10 ],
        scope       => [ $line, $line ],
    );
}

subtest 'the grammar reads each accepted form as a range of lines' => sub {
    is ranges( comment( 3, '## no mutate' ) ), [ [ 3, 3, 3, undef, undef ] ], 'a comment behind code covers its line';
    is ranges( comment( 3, '## no mutate (arithmetic, comparison-boundary): the sum is a constant' ) ),
      [ [ 3, 3, 3, [ 'arithmetic', 'comparison-boundary' ], 'the sum is a constant' ] ], 'with names and a reason';
    is ranges( comment( 3, '## no mutate: the port is fixed' ) ), [ [ 3, 3, 3, undef, 'the port is fixed' ] ],
      'with a reason alone';
    is ranges( own( 2, '## no mutate (logical)' ), own( 6, '## use mutate' ) ),
      [ [ 2, 2, 6, ['logical'], undef ] ], 'a block runs from its comment to the end';
    is ranges( own( 2, '## no mutate sub (arithmetic): cosmetic', routine => [ 3, 7 ] ) ),
      [ [ 2, 3, 7, ['arithmetic'], 'cosmetic' ] ], 'a comment before a subroutine covers its lines';
    is ranges(
        own( 1, '## no mutate' ),
        comment( 2, '## no mutate' ),
        own( 3, '## no mutate sub', routine => [ 4, 4 ] ),
        own( 5, '## use mutate' ),
        own( 6, '## no mutate' ),
        own( 9, '## use mutate' ),
      ),
      [ [ 1, 1, 5, undef, undef ], [ 2, 2, 2, undef, undef ], [ 3, 4, 4, undef, undef ], [ 6, 6, 9, undef, undef ] ],
      'a line and a subroutine inside a block, and a second block after the end of the first';
    is ranges( own( 1, '## no mutate' ) ), [ [ 1, 1, undef, undef, undef ] ], 'a block that the file leaves open';
    is ranges( comment( 1, '# a comment' ), own( 2, '## no critic (ProhibitMagicNumbers)' ), comment( 3, '#' ) ), [],
      'comments that resemble no directive';
};

subtest 'the grammar refuses every candidate that breaks it, and reads on' => sub {
    my @malformed = (
        '# no mutate',
        '##no mutate',
        '## no mutation',
        '##  no mutate',
        '## No Mutate',
        '### no mutate',
        '## no mutate()',
        '## no mutate (arithmetic,comparison-boundary)',
        '## no mutate (Arithmetic)',
        '## no mutate (arithmetic) trailing words',
        '## no mutate:',
        '## no mutate:no space',
        '#no mutat',
        '# use mutate',
        '## no  mutate sub',
    );
    is refused( map { comment( 4, $_ ) } @malformed ), [ map { [ 4, 'suppression-malformed' ] } @malformed ],
      'a candidate in another form than the grammar';
    is refused( comment( 4, '## use mutate' ), comment( 5, '## no mutate sub' ) ),
      [ [ 4, 'suppression-malformed' ], [ 5, 'suppression-malformed' ] ], 'an end and a subroutine behind code';
    is refused(
        own( 1, '## no mutate' ),
        own( 2, '## use mutate (arithmetic)' ),
        own( 3, '## use mutate: done' ),
        own( 4, '## use mutate sub' ),
        own( 5, '## use mutate' )
      ),
      [ map { [ $_, 'suppression-malformed' ] } 2 .. 4 ], 'an end with a name, a reason, or a subroutine';
    is refused( comment( 3, '##no mutate' ), comment( 4, '## no mutate (arithmetc, comparison-boundary, nonesuch)' ) ),
      [ [ 3, 'suppression-malformed' ], [ 4, 'suppression-mutator-unknown' ] ], 'an unknown name';
    is parsed( comment( 4, '## no mutate (arithmetc, comparison-boundary, nonesuch)' ) )->{refusals}[0]{text},
      'lib/A.pm:4: unknown mutator arithmetc, nonesuch', 'the refusal names every unknown name';
    is refused( own( 4, '## no mutate (arithmetc)' ), own( 5, '## use mutate' ) ),
      [ [ 4, 'suppression-mutator-unknown' ], [ 5, 'suppression-end-unopened' ] ],
      'a refused comment opens no block';
    is refused( own( 4, '## use mutate' ) ), [ [ 4, 'suppression-end-unopened' ] ], 'an end without a block';
    is refused( own( 1, '## no mutate' ), own( 2, '## use mutate' ), own( 3, '## use mutate' ) ),
      [ [ 3, 'suppression-end-unopened' ] ], 'an end closes one block';
    is refused( own( 1, '## no mutate' ), own( 3, '## no mutate (arithmetic)' ), own( 5, '## use mutate' ) ),
      [ [ 3, 'suppression-block-nested' ] ], 'a block inside an open block';
    is ranges( own( 1, '## no mutate' ), own( 3, '## no mutate (arithmetic)' ), own( 5, '## use mutate' ) ),
      [ [ 1, 1, 5, undef, undef ] ], 'and the end closes the first block';
    is refused( own( 2, '## no mutate' ), comment( 3, '## no mutate' ) ), [ [ 2, 'suppression-block-unclosed' ] ],
      'a block that the file leaves open';
    is refused( own( 2, '## no mutate sub' ) ), [ [ 2, 'suppression-sub-missing' ] ],
      'a comment before a statement that is no subroutine';
    is refused(
        comment( 7, '## no mutate (nonesuch)' ),
        own( 8, '## use mutate' ),
        own( 9, '## no mutate' ),
        comment( 10, '##no mutate' )
      ),
      [
        [ 7,  'suppression-mutator-unknown' ],
        [ 8,  'suppression-end-unopened' ],
        [ 10, 'suppression-malformed' ],
        [ 9,  'suppression-block-unclosed' ]
      ],
      'every refusal of a file, and the open block at the end of the file';
};

subtest 'a refusal names the file, the line, and the comment' => sub {
    my @comments = (
        comment( 1, '## no mutate (' ),
        own( 2, '## use mutate' ),
        own( 3, '## no mutate' ),
        own( 4, '## no mutate' ),
        own( 5, '## no mutate sub' ),
    );
    is [ map { $_->{text} } parsed(@comments)->{refusals}->@* ],
      [
        'lib/A.pm:1: "## no mutate (" differs from the grammar',
        'lib/A.pm:2: ## use mutate ends no open block',
        'lib/A.pm:4: ## no mutate opens a block inside the block of line 3',
        'lib/A.pm:5: ## no mutate sub stands before no named subroutine or method',
        'lib/A.pm:3: ## no mutate opens a block that no ## use mutate ends',
      ],
      'the text of each refusal';
};

subtest 'a mutant falls under the last comment that covers its first line and its mutator' => sub {
    my $directives = parsed(
        own( 1, '## no mutate: the block' ),
        comment( 3, '## no mutate (arithmetic): the line' ),
        own( 4,  '## use mutate' ),
        own( 5,  '## no mutate sub (comparison-boundary)', routine => [ 6, 8 ] ),
        own( 10, '## no mutate (logical)' ),
    )->{directives};
    my $reason = sub ( $line, $mutator ) {
        my $directive = Test::Mutation::Suppression::covering( $directives, $line, $mutator );
        return 'none' if !$directive;
        return defined $directive->{reason} ? $directive->{reason} : 'no reason';
    };
    is [ map { $reason->( @{$_} ) } [ 2, 'arithmetic' ], [ 3, 'arithmetic' ], [ 3, 'logical' ], [ 4, 'logical' ] ],
      [ 'the block', 'the line', 'the block', 'the block' ], 'the block, and the line inside it';
    is [
        map { $reason->( @{$_} ) } [ 5, 'comparison-boundary' ],
        [ 6, 'comparison-boundary' ],
        [ 8, 'comparison-boundary' ],
        [ 9, 'comparison-boundary' ]
      ],
      [ 'none', 'no reason', 'no reason', 'none' ], 'the lines of a subroutine and no line around them';
    is [ map { $reason->( @{$_} ) } [ 7, 'arithmetic' ], [ 10, 'arithmetic' ], [ 99, 'logical' ], [ 9, 'logical' ] ],
      [ 'none', 'none', 'no reason', 'none' ], 'the names narrow a range, and an open block runs to the end';
};

subtest 'the run refuses a comment that suppresses no mutant, and asks for names and reasons on request' => sub {
    my $suppression = parsed(
        comment( 2, '## no mutate' ),
        comment( 3, '## no mutate (comparison-boundary): the boundary is free' ),
        own( 5, '## no mutate (arithmetic)' ),
        own( 7, '## use mutate' ),
        own( 1, '## use mutate' ),
    );
    my $refusals = sub ( $mutants, %policy ) {
        my $found = Test::Mutation::Suppression::refusals(
            path        => $PATH,
            suppression => $suppression,
            mutants     => $mutants,
            %policy
        );
        return [ map { [ $_->@{qw(line id)} ] } $found->@* ];
    };
    my @mutants = ( mutant( 2, 'logical' ), mutant( 3, 'comparison-boundary' ), mutant( 6, 'arithmetic' ) );
    is $refusals->( \@mutants ), [ [ 1, 'suppression-end-unopened' ] ], 'each comment covers a mutant';
    is $refusals->( [ mutant( 2, 'logical' ), mutant( 3, 'arithmetic' ), mutant( 7, 'arithmetic' ) ] ),
      [ [ 1, 'suppression-end-unopened' ], [ 3, 'suppression-unused' ] ],
      'a comment whose line holds mutants of other mutators alone, and a block that ends on the line of a mutant';
    is $refusals->( [ mutant( 1, 'logical' ), mutant( 4, 'comparison-boundary' ), mutant( 8, 'arithmetic' ) ] ),
      [
        [ 1, 'suppression-end-unopened' ],
        [ 2, 'suppression-unused' ],
        [ 3, 'suppression-unused' ],
        [ 5, 'suppression-unused' ]
      ],
      'mutants on the lines around each range, in the order of the lines';
    is $refusals->( \@mutants, require_names => 1 ),
      [ [ 1, 'suppression-end-unopened' ], [ 2, 'suppression-names-missing' ] ],
      'a comment without a name, when the names are required';
    is $refusals->( \@mutants, require_reason => 1 ),
      [ [ 1, 'suppression-end-unopened' ], [ 2, 'suppression-reason-missing' ], [ 5, 'suppression-reason-missing' ] ],
      'the comments without a reason, when a reason is required';
    is [
        map { $_->{text} } Test::Mutation::Suppression::refusals(
            path           => 'lib/B.pm',
            suppression    => $suppression,
            mutants        => [],
            require_names  => 1,
            require_reason => 1
        )->@*
      ],
      [
        'lib/A.pm:1: ## use mutate ends no open block',
        'lib/B.pm:2: "## no mutate" names no mutator, and suppress-require-names asks for one',
        'lib/B.pm:2: "## no mutate" gives no reason, and suppress-require-reason asks for one',
        'lib/B.pm:2: "## no mutate" suppresses no mutant',
        'lib/B.pm:3: "## no mutate (comparison-boundary): the boundary is free" suppresses no mutant',
        'lib/B.pm:5: "## no mutate (arithmetic)" gives no reason, and suppress-require-reason asks for one',
        'lib/B.pm:5: "## no mutate (arithmetic)" suppresses no mutant',
      ],
      'the text of each refusal names the given file, in the order of the lines and of the checks';
};

sub unwired ( $attributes, $analyze ) {
    my @unwired;
    for my $setting (qw(suppress-require-names suppress-require-reason)) {
        my $attribute = $attributes->{$setting};
        if ( !$attribute ) {
            push @unwired, "the settings table holds no $setting";
            next;
        }
        my $refused = dies { $analyze->($attribute) };
        push @unwired, "a run with $setting accepts a comment that lacks what it asks for"
          if !defined $refused || index( "$refused", "$setting asks for one" ) < 0;
    }
    return \@unwired;
}

subtest 'the check of the settings rejects a table without them and a run that ignores them' => sub {
    my %attributes = (
        'suppress-require-names'  => 'suppress_require_names',
        'suppress-require-reason' => 'suppress_require_reason'
    );
    is unwired( {}, sub ($attribute) { } ),
      [ 'the settings table holds no suppress-require-names', 'the settings table holds no suppress-require-reason' ],
      'a table without the settings';
    is unwired( \%attributes, sub ($attribute) { } ),
      [
        'a run with suppress-require-names accepts a comment that lacks what it asks for',
        'a run with suppress-require-reason accepts a comment that lacks what it asks for'
      ],
      'a run that ignores them';
    is unwired( \%attributes, sub ($attribute) { die( ( $attribute =~ tr/_/-/r ) . " asks for one\n" ) } ), [],
      'a run that refuses the comment for each of them';
};

my $root = File::Temp::tempdir( CLEANUP => 1 );
Fixture::write_file( "$root/lib/A.pm", "package A;\nmy \$sum = 1 + 2;    ## no mutate\n1;\n" );
my $found = unwired(
    { map { $_->name => $_->attribute } Test::Mutation::Settings::rows()->@* },
    sub ($attribute) {
        Test::Mutation::mutants( root => $root, $attribute => 1 );
    }
);
Gate::findings( 'suppression-settings', $found );
Gate::checked( 'settings of the suppression comments', 2, at_least => 2 );

done_testing;
