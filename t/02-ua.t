#!perl
use strict;
use utf8;
use warnings qw(all);

use FindBin qw($Bin $Script);
use LWP::Protocol::Net::Curl;
use LWP::UserAgent;
use Test::HTTP::Server;
use Test::More;

my $server = Test::HTTP::Server->new;

my $now = time;

my $ua = LWP::UserAgent->new;
my $res = $ua->post(
    $server->uri . q(echo/body),
    q(Accept-Encoding) => q(gzip, bzip2),
    Content => { a => 1, b => 2, c => 3, time => $now },
);

isa_ok($res, q(HTTP::Response));
ok($res->is_success, q(is_success));
like($res->decoded_content, qr/\b${now}\b/sx, q(content pingback));

$res = $ua->put($server->uri . q(echo/body));
is($res->code, 200, q(PUT));

$res = $ua->delete($server->uri . q(echo/body));
is($res->code, 200, q(DELETE));

$res = $ua->request(HTTP::Request->new(DUMMY => $server->uri . q(echo/body)));
is($res->code, 400, q(unsupported method));

LWP::Protocol::implementor(file => q(LWP::Protocol::Net::Curl));
$res = $ua->get(qq(file://$Bin/$Script), q(Accept-Encoding) => q(dummy));
is(length $res->content, -s __FILE__, q(quine));

done_testing(7);
