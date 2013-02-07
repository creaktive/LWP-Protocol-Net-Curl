#!perl
use strict;
use utf8;
use warnings qw(all);

BEGIN {
    use Test::More;
    diag q(it's OK to see warnings here);
}

use LWP::Protocol::Net::Curl
    _DUMMY1 => 12345;

use LWP::UserAgent;
use Net::Curl::Easy;

my $easy = Net::Curl::Easy->new({});
isa_ok($easy, q(Net::Curl::Easy));

## no critic (ProtectPrivateSubs)
LWP::Protocol::Net::Curl::_setopt_ifdef($easy, _DUMMY2 => 1 => 1);

my $ua = LWP::UserAgent->new;
my $res = $ua->get(q(http://127.0.0.1:0/));
ok($res->is_error, q(bad address 1));
like($res->message, qr/couldn't\s+connect\s+to\s+server/ix, q(bad address 2));

done_testing(3);
