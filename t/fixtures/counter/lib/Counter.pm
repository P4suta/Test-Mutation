use v5.38;
use experimental 'class';

class Counter 1.0 {
    field $count :param = 0;
    field $limit = 10 + 5;

    ADJUST {
        $count = $count + 0;
    }

    method bump ( $by = 1 ) {
        $count += $by;
        return $self;
    }

    method count { return $count }

    method limit { return $limit }

    method minute { return 60 + 0 }
}

1;
