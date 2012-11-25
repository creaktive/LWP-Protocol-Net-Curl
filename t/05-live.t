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
        PeerPort  => 443,
        Proto     => q(tcp),
        Timeout   => 10,
    );

my $ua = LWP::UserAgent->new;
$ua->ssl_opts(verify_hostname => 0);

my $res;

SKIP1: {
    skip q(no HTTPS support), 3
        unless grep { $_ eq q(https) } @LWP::Protocol::Net::Curl::implements;

    $res = $ua->get(q(https://google.com));
    ok($res->is_success, q(HTTPS is_success()));
    ok($res->is_redirect ? 0 : 1, q(HTTPS not is_redirect()));
    ok($res->redirects > 0, q(HTTPS redirects() == ) . $res->redirects);
};

SKIP2: {
    $res = $ua->get(q(ftp://ftp.kernel.org/pub/README_ABOUT_BZ2_FILES));
    skip q(FTP unreachable), 2
        if $res->is_error;

    ok($res->is_success, q(FTP is_success()));
    like($res->content, qr(^This\s+file\s+describes\b), q(FTP content() start));
};

SKIP3: {
    $res = $ua->get(q(gopher://gopher.docfile.org/1/world/monitoring/uptime));
    skip q(gopher unreachable), 2
        if $res->is_error;

    ok($res->is_success, q(gopher is_success()));
    like($res->content, qr(\bUptime\s+known\s+gopher\s+servers\b), q(gopher content() start));
};

# known to have a long redir chain
$ua->max_redirect(1);
$ua->show_progress(1);
$res = $ua->get(q(http://terra.com.br));
ok($res->is_redirect, q(is_redirect()));

done_testing(8);
