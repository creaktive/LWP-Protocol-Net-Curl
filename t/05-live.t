#!perl
use strict;
use utf8;
use warnings qw(all);

use IO::Socket::INET;
use LWP::Protocol::Net::Curl;
use LWP::UserAgent;
use Test::More;

plan skip_all => q(Internet connection timed out)
    unless IO::Socket::INET->new(
        PeerHost  => q(google.com),
        PeerPort  => 80,
        Proto     => q(tcp),
        Timeout   => 10,
    );

my $ua = LWP::UserAgent->new;
my $res;

SKIP: {
    skip q(no HTTPS support), 3
        unless grep { $_ eq q(https) } @LWP::Protocol::Net::Curl::implements;

    $res = $ua->get(q(https://google.com));
    ok($res->is_success, q(HTTPS is_success()));
    ok($res->is_redirect ? 0 : 1, q(HTTPS not is_redirect()));
    ok($res->redirects > 0, q(HTTPS redirects() == ) . $res->redirects);
};

# known to have a long redir chain
$ua->max_redirect(1);
$res = $ua->get(q(http://terra.com.br));
ok($res->is_redirect, q(is_redirect()));

$res = $ua->get(q(ftp://ftp.kernel.org/pub/README_ABOUT_BZ2_FILES));
ok($res->is_success, q(FTP is_success()));
like($res->content, qr(^This\s+file\s+describes\b), q(FTP content() start));

done_testing(6);
