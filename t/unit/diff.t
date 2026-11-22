use v5.36;
use Test2::V0;
use Permutl::Diff;

my $diff = <<'DIFF';
diff --git a/lib/Calc.pm b/lib/Calc.pm
index 1111111..2222222 100644
--- a/lib/Calc.pm
+++ b/lib/Calc.pm
@@ -7 +7 @@ sub add {
-    return $x + $y;
+    return $x + $y + 0;
@@ -12,0 +13,3 @@ sub is_positive {
+    # three
+    # added
+    # lines
@@ -20,2 +23,0 @@ sub describe {
-    my ($n) = @_;
-    my $label = 'zero';
diff --git a/lib/New File.pm b/lib/New File.pm
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/lib/New File.pm
@@ -0,0 +1,2 @@
+package New;
+1;
diff --git a/lib/Gone.pm b/lib/Gone.pm
deleted file mode 100644
index 4444444..0000000
--- a/lib/Gone.pm
+++ /dev/null
@@ -1,2 +0,0 @@
-package Gone;
-1;
DIFF

subtest 'changed_lines reads the new side of every hunk' => sub {
    is Permutl::Diff::changed_lines($diff),
      { 'lib/Calc.pm' => [ [ 7, 7 ], [ 13, 15 ] ], 'lib/New File.pm' => [ [ 1, 2 ] ] },
      'modified and added lines by file, without deleted lines and deleted files';
    is Permutl::Diff::changed_lines(q{}), {}, 'an empty diff';
};

subtest 'touches tells whether a line range meets a changed range' => sub {
    my $ranges = [ [ 7, 7 ], [ 13, 15 ] ];
    my @cases  = ( [ 7, 7, 1 ], [ 6, 6, 0 ], [ 8, 12, 0 ], [ 1, 30, 1 ], [ 15, 20, 1 ], [ 16, 20, 0 ], [ 12, 13, 1 ] );
    for my $case (@cases) {
        my ( $first, $last, $expected ) = $case->@*;
        is Permutl::Diff::touches( $ranges, $first, $last ), $expected, "lines $first to $last";
    }
    is Permutl::Diff::touches( [], 1, 100 ), 0, 'no changed range';
};

done_testing;
