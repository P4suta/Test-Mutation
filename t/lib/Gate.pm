package Gate;
use v5.36;
use Test2::API qw(context intercept);

my $OPEN_FINDINGS = 't/open-findings.tsv';

# The outcome of every assertion that a piece of test code makes, for a subtest that expects a rejection.
sub outcomes ($code) {
    my @facets = map { $_->facet_data } intercept { $code->() }->@*;
    return [ map { $_->{assert}{pass} ? 'pass' : 'fail' } grep { $_->{assert} } @facets ];
}

# A gate that checked nothing passes for the wrong reason, so every gate states its count and a floor.
sub checked ( $what, $count, %arg ) {
    die "checked needs a floor: at_least\n" if !defined $arg{at_least};
    my $context = context();
    my $enough  = $count >= $arg{at_least} ? 1 : 0;
    $context->ok( $enough, "the gate checked $count $what, at least $arg{at_least}" );
    $context->release;
    return $enough;
}

sub _listed ($file) {
    open my $handle, '<:encoding(UTF-8)', $file or die "cannot read $file: $!\n";
    my ( %remover, $number );
    while ( my $line = readline $handle ) {
        $number++;
        chomp $line;
        my ( $gate, $finding, $remover, @rest ) = split /\t/, $line, -1;
        die "line $number of $file needs a gate, a finding, and what removes it\n"
          if @rest || grep { !defined || !length } $gate, $finding, $remover;
        die "line $number of $file repeats a finding\n" if exists $remover{$gate}{$finding};
        $remover{$gate}{$finding} = $remover;
    }
    close $handle or die "cannot close $file: $!\n";
    return \%remover;
}

# The open findings are the violations that a named piece of work still has to remove.
# A violation outside the list fails, and so does a listed one that is gone, so the list shrinks with the work.
sub findings ( $gate, $found, %arg ) {
    my $file    = defined $arg{file} ? $arg{file} : $OPEN_FINDINGS;
    my $listed  = _listed($file)->{$gate} || {};
    my %found   = map       { $_ => 1 } $found->@*;
    my @new     = sort grep { !exists $listed->{$_} } keys %found;
    my @gone    = sort grep { !$found{$_} } keys $listed->%*;
    my $context = context();
    $context->ok( !@new,  "$gate: every finding is an open finding of $file", [ map { "new: $_" } @new ] );
    $context->ok( !@gone, "$gate: every open finding still reproduces",       [ map { "gone: $_" } @gone ] );
    $context->release;
    return !@new && !@gone ? 1 : 0;
}

1;
