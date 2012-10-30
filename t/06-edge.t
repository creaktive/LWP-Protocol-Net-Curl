#!perl
use strict;
use utf8;
use warnings qw(all);

BEGIN {
    use Test::More;
    diag q(it's OK to see warnings here);
};

use LWP::Protocol::Net::Curl
    _DUMMY => 12345;

use LWP::UserAgent;

my $ua = LWP::UserAgent->new;
my $res = $ua->get(q(http://127.0.0.1:0/));
ok($res->is_error, q(bad address 1));
like($res->message, qr/couldn't\s+connect\s+to\s+server/ix, q(bad address 2));

done_testing(2);
