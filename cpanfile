use strict;
use warnings;
requires 'perl', '5.036';

requires 'DBI',          '1.643';
requires 'DBD::SQLite',  '1.72';
requires 'Moo',          '2.005005';
requires 'PPI',          '1.291';
requires 'PPIx::Regexp', '0.092';
requires 'TAP::Parser',  '3.48';
requires 'TOML::Tiny',   '0.22';
requires 'Type::Tiny',   '2.010001';

on test => sub {
    requires 'Test2::Suite', '0.000162';
};

on develop => sub {
    requires 'App::cpm',           'v1.1.7';
    requires 'CPAN::Audit',        '20240000';
    requires 'Carton',             '1.0.35';
    requires 'Devel::Cover',       '1.52';
    requires 'JSON::Schema::Tiny', '0.034';
    requires 'Perl::Critic',       '1.156';
    requires 'Perl::Tidy',         '20240903';
    requires 'Test::Pod',          '1.52';
};
