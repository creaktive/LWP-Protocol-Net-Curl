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

my $res = $ua->get(q(https://www.google.com));
ok($res->is_success, q(https));

#use Data::Dumper;
#diag Dumper $res;

$res = $ua->get(q(ftp://ftp.kernel.org/pub/README_ABOUT_BZ2_FILES));
ok($res->is_success, q(ftp 1));
like($res->content, qr(\Qftp://mirrors.kernel.org/sources.redhat.com/bzip2/\E), q(ftp 2));

done_testing(3);
