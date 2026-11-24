use strict;
use warnings;
use Test::More;
use Cwd        ();
use Errno      ();
use File::Temp ();

# Experiment E14: the placement of a mutant writes a temporary file and renames it over the target.
# A built distribution keeps its copies under blib with mode 0444, so the rename has to work over a file that nobody may write.

my $dir = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $who = $> == 0 ? 'the superuser' : 'a user';

sub write_file {
    my ( $path, $content, $mode ) = @_;
    open my $handle, '>', $path or die "write $path: $!";
    print {$handle} $content or die "print $path: $!";
    close $handle            or die "close $path: $!";
    chmod $mode, $path or die "chmod $path: $!";
    return $path;
}

sub slurp {
    my ($path) = @_;
    open my $handle, '<', $path or die "read $path: $!";
    local $/ = undef;
    my $content = <$handle>;
    close $handle or die "close $path: $!";
    return $content;
}

sub mode_of {
    my ($path) = @_;
    return sprintf '%04o', ( stat $path )[2] & oct '7777';
}

sub inode_of {
    my ($path) = @_;
    return ( stat $path )[1];
}

my $target = write_file( "$dir/Target.pm", "original\n", oct '444' );
link $target, "$dir/Twin.pm" or die "link: $!";
my $old_inode = inode_of($target);

# The control: the mode does forbid a write in place, except to the superuser.
my $opened = open my $in_place, '>>', $target;
my $denied = $!{EACCES} ? 1 : 0;
close $in_place or die "close: $!" if $opened;
if ( $> == 0 ) {
    ok $opened, 'the superuser opens a file with mode 0444 for a write in place';
}
else {
    ok !$opened && $denied, 'a user cannot open a file with mode 0444 for a write in place';
}

my $temporary = write_file( "$dir/Target.pm.new", "mutant\n", oct '444' );
my $new_inode = inode_of($temporary);
ok rename( $temporary, $target ), "E14: $who renames a temporary file over a file with mode 0444" or diag $!;
is slurp($target),    "mutant\n", 'E14: the name holds the new text';
is mode_of($target),  '0444',     'E14: with the mode that the temporary file had';
is inode_of($target), $new_inode, 'E14: the name now belongs to the temporary file';
isnt $new_inode,      $old_inode, 'E14: which is another file than the old one';
ok !-e $temporary, 'E14: and the temporary name is gone';
is slurp("$dir/Twin.pm"), "original\n", 'E14: a second name of the old file keeps the old text';

# A temporary file keeps its own mode through the rename, so the placement gives it the mode of the target first.
my $private = write_file( "$dir/Target.pm.private", "restored\n", oct '600' );
ok rename( $private, $target ), "E14: $who renames over the placed file once more";
is mode_of($target), '0600',
  'E14: the name takes the mode of the file that arrived, not the mode of the file it replaced';

# The control: a rename needs the directory, and a directory without write permission refuses a user.
my $closed = "$dir/closed";
mkdir $closed or die "mkdir: $!";
write_file( "$closed/Target.pm",     "original\n", oct '444' );
write_file( "$closed/Target.pm.new", "mutant\n",   oct '444' );
chmod oct '555', $closed or die "chmod: $!";
my $renamed = rename "$closed/Target.pm.new", "$closed/Target.pm";
my $refused = $!{EACCES} ? 1 : 0;
chmod oct '755', $closed or die "chmod: $!";

if ( $> == 0 ) {
    ok $renamed, 'E14: the superuser renames inside a directory with mode 0555';
}
else {
    ok !$renamed && $refused, 'E14: a user cannot rename inside a directory with mode 0555';
}

done_testing;
