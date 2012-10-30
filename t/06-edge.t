#!perl
use strict;
use utf8;
use warnings qw(all);

BEGIN {
    use Test::More;
    diag q(OK to see warnings here);
};

use LWP::Protocol::Net::Curl
    _DUMMY => 12345;

use LWP::Simple;

is(
    get(q(http://127.0.0.1:0/)),
    undef,
    q(bad address)
);

done_testing(1);
