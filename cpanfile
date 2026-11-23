requires 'perl', '5.036';

requires 'Moo',         '2.004000';
requires 'PPI',         '1.281';
requires 'PPIx::Regexp', '0.080';
requires 'TOML::Tiny',  '0.15';
requires 'Type::Tiny',  '2.000000';

on test => sub {
    requires 'Test2::Suite', '0.000155';
};

on develop => sub {
    requires 'App::cpm',      '0.997';
    requires 'CPAN::Audit',   '20240000';
    requires 'Carton',        '1.0.35';
    requires 'JSON::Schema::Tiny', '0.034';
    requires 'Perl::Critic',  '1.156';
    requires 'Perl::Tidy',    '20240903';
    requires 'Pod::Coverage', '0.23';
    requires 'Test::Pod',     '1.52';
};
