package LibraryCoverage;
use v5.36;

sub sources ( $modules, $measured, $root ) {
    my %needed = map { $_ => 1 } @$modules;
    my %selected;
    for my $path (@$measured) {
        my $relative = $path =~ s{^\Q$root/\E}{}r;
        next unless $needed{$relative};
        die "duplicate coverage for $relative\n" if exists $selected{$relative};
        $selected{$relative} = $path;
    }
    for my $path (@$modules) {
        die "missing coverage for $path\n" unless exists $selected{$path};
    }
    return [ @selected{@$modules} ];
}

sub floors ($lines) {
    my %floors;
    for my $line (@$lines) {
        chomp $line;
        my ( $criterion, $covered, $total ) = $line =~ /\A(statement|branch)\t(0|[1-9][0-9]*)\t([1-9][0-9]*)\z/;
        die "invalid coverage floor: $line\n"       if !defined $criterion || $covered > $total;
        die "duplicate $criterion coverage floor\n" if exists $floors{$criterion};
        $floors{$criterion} = [ 0 + $covered, 0 + $total ];
    }
    for my $criterion (qw(statement branch)) {
        die "missing $criterion coverage floor\n" unless exists $floors{$criterion};
    }
    return \%floors;
}

sub findings ( $counts, $floors ) {
    my @found;
    for my $criterion (qw(statement branch)) {
        my ( $covered,  $total ) = $counts->{$criterion}->@*;
        my ( $required, $base )  = $floors->{$criterion}->@*;
        if ( !$total ) {
            push @found, "$criterion coverage has no observations";
        }
        elsif ( $covered * $base < $required * $total ) {
            push @found, "$criterion coverage $covered/$total is below $required/$base";
        }
    }
    return \@found;
}

1;
