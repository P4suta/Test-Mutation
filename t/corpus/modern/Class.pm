use v5.38;
use experimental 'class';

class Corpus::Point 1.0 {
    field $x :param = 0;
    field $y :param = 0;
    field @history;

    ADJUST {
        push @history, [ $x, $y ];
    }

    method move ($dx, $dy = 0) {
        $x += $dx;
        $y += $dy;
        push @history, [ $x, $y ];
        return $self;
    }

    method distance {
        return sqrt( $x * $x + $y * $y );
    }

    method steps { scalar(@history) - 1 }
}

class Corpus::Point3D :isa(Corpus::Point) {
    field $z :param //= 0;

    method depth { $z }
}

1;
