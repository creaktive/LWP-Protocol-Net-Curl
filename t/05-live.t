#!perl
use strict;
use utf8;
use warnings qw(all);

use LWP::Protocol::Net::Curl;

use LWP::UserAgent;
use Test::More;

plan skip_all => q(Internet connection required)
    unless exists $ENV{LIVE_TESTING};

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

$res = $ua->get(q(ftp://ftp.kernel.org/pub/README_ABOUT_BZ2_FILES));
ok($res->is_success, q(FTP is_success()));
like($res->content, qr(^This\s+file\s+describes\b), q(FTP content() start));

$res = $ua->get(q(gopher://gopher.docfile.org/1/world/monitoring/uptime));
ok($res->is_success, q(gopher is_success()));
like($res->content, qr(\bUptime\s+known\s+gopher\s+servers\b), q(gopher content() start));

# known to have a long redir chain
$ua->max_redirect(1);
$ua->show_progress(1);
$res = $ua->get(q(http://terra.com.br));
ok($res->is_redirect, q(is_redirect()));

done_testing(8);
