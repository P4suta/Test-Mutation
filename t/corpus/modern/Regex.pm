package Corpus::Regex;
use v5.36;

sub words ($text) {
    my @words = $text =~ m{ (\w+) }gx;
    return scalar @words;
}

sub squeeze ($text) {
    ( my $copy = $text ) =~ s/\s+/ /g;
    $copy =~ tr/a-z/A-Z/;
    return $copy;
}

sub ratio ($total, $parts) {
    return $total / $parts if $parts != 0;
    return 0;
}

sub default_or ($value) {
    my $fallback = $value // 1;
    return $fallback / 2;
}

sub looks_empty ($text) {
    return $text !~ /\S/ || $text =~ /^#/;
}

sub upcase_words ($text) {
    $text =~ s/(\w+)/uc($1) . '!'/ge;
    return $text;
}

1;
