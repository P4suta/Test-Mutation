use v5.36;
use Test2::V0;
use File::Temp ();

# A close that fails means lost data or an unread error, so the library checks every close.
# The override below closes the handle and then reports a failure to the subroutine that the pattern names.
our $failing;

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::close = sub : prototype(;*) (@handle) {
        my $closed = @handle ? CORE::close( $handle[0] ) : CORE::close();
        my $caller = ( caller 1 )[3] || 'main';
        return $closed if !defined $failing || $caller !~ $failing;
        $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
}

use Permutl::Cache;
use Permutl::Config;
use Permutl::Project;
use Permutl::Record;
use Permutl::Report::Html;

my $directory = File::Temp::tempdir( CLEANUP => 1 );

sub write_file ( $name, $text ) {
    open my $handle, '>', "$directory/$name" or die "write $name: $!";
    print {$handle} $text or die "write $name: $!";
    CORE::close($handle)  or die "close $name: $!";
    return "$directory/$name";
}

sub failing_in ( $pattern, $code ) {
    local $failing = $pattern;
    return $code->();
}

my $record =
  { key => 'k', status => 'Killed', reason => undef, by => 't/a.t', tests_run => 1, duration => 0.1, code => undef };
my $cache = "$directory/cache.json";
is Permutl::Cache::save( $cache, { abc => $record } ), 1,       'the cache is written';
is [ keys Permutl::Cache::load($cache)->%* ],          ['abc'], 'and read back';
is failing_in( qr/::Cache::load\z/, sub { Permutl::Cache::load($cache) } ), {},
  'a cache that does not close counts as no cache';
like dies {
    failing_in( qr/::Cache::save\z/, sub { Permutl::Cache::save( $cache, { abc => $record } ) } )
}, qr/\Aclose \Q$cache\E[.]\d+: /, 'a cache that does not close after the write stops the run';

my $settings = write_file( 'permutl.toml', "jobs = 2\n" );
is Permutl::Config::read_file($settings), { jobs => 2 }, 'the configuration file is read';
like dies {
    failing_in( qr/::Config::read_file\z/, sub { Permutl::Config::read_file($settings) } )
}, qr/\Acannot close \Q$settings\E: /, 'a configuration file that does not close is an error';

my $records = write_file( 'one.rec', "begin\t0\nbypass\t/p/A.pm\n" );
is Permutl::Record::read_directory($directory)->{bypassed}, { '/p/A.pm' => 1 }, 'the record file is read';
like dies {
    failing_in( qr/::Record::read_directory\z/, sub { Permutl::Record::read_directory($directory) } )
}, qr/\Acannot close \Q$records\E: /, 'a record file that does not close is an error';

is failing_in( qr/::Project::_read\z/, sub { Permutl::Project::cpu_count() } ), 1,
  'a processor count that does not close counts as no answer';

ok length Permutl::Report::Html::viewer_script(), 'the viewer script is read';
like dies {
    failing_in( qr/::Html::viewer_script\z/, sub { Permutl::Report::Html::viewer_script() } )
}, qr/\Acannot close \S+mutation-test-elements[.]js: /, 'a viewer script that does not close is an error';

done_testing;
