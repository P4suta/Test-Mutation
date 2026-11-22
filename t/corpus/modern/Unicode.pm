package Corpus::Unicode;
use v5.36;
use utf8;

sub greeting ($name) {
    my $挨拶 = "こんにちは、";
    return $挨拶 . $name . "さん" if length($name) > 0;
    return "名無し";
}

sub width ($text) {
    my $幅 = length($text) * 2;    # 全角は2桁
    return $幅 + 1;
}

1;
