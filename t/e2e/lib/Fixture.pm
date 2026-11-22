package Fixture;
use v5.36;
use Cwd         ();
use Digest::SHA ();
use File::Find  ();
use File::Path  ();
use File::Temp  ();
use Exporter 'import';
use Permutl::Config;
use Permutl::Runner;

our @EXPORT_OK = qw(copy_of run_fixture tree_digest statuses);

sub copy_of ($name) {
    my $source = Cwd::abs_path("t/fixtures/$name");
    my $target = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $relative = substr $File::Find::name, length $source;
                return File::Path::make_path("$target$relative") if -d $File::Find::name;
                open my $in,  '<:raw', $File::Find::name  or die "read $File::Find::name: $!";
                open my $out, '>:raw', "$target$relative" or die "write $target$relative: $!";
                local $/ = undef;
                print {$out} readline $in or die "copy $relative: $!";
                close $out                or die "close $relative: $!";
            },
        },
        $source,
    );
    return $target;
}

sub tree_digest ($root) {
    my %digest;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if !-f $File::Find::name;
                $digest{ substr $File::Find::name, length($root) + 1 } =
                  Digest::SHA->new(256)->addfile($File::Find::name)->hexdigest;
            },
        },
        $root,
    );
    return \%digest;
}

sub run_fixture ( $root, %settings ) {
    my $config = Permutl::Config->new( root => $root, jobs => 2, %settings );
    my @events;
    my $result = Permutl::Runner::run( $config, sub ( $event, $data ) { push @events, $event } );
    return ( $result, \@events );
}

sub statuses ($result) {
    return {
        map {
            my $mutant = $_->{mutant};
            sprintf( '%s:%d %s', $mutant->path, $mutant->from->[0], $mutant->description ) => $_->{status}
        } $result->entries->@*
    };
}

1;
