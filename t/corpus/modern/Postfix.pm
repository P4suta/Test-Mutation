package Corpus::Postfix;
use v5.36;

sub count ($list) {
    return scalar $list->@*;
}

sub last_index ($list) {
    return $list->$#*;
}

sub names ($table) {
    return sort keys $table->%*;
}

sub slice ($list) {
    my @head = $list->@[ 0 .. 1 ];
    return "@head and $list->@*";
}

sub is_point ($thing) {
    return $thing isa Corpus::Point || ref $thing eq 'ARRAY';
}

1;
