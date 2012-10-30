#!/usr/bin/env perl
use strict;
use utf8;
use warnings qw(all);

use Benchmark::Forking qw(cmpthese);
use Class::Load qw(load_class);
use LWP::UserAgent;

cmpthese(10 => {
    q(LWP::Protocol::http) => sub {
        fetch();
    },
    q(LWP::Protocol::Net::Curl) => sub {
        load_class(q(LWP::Protocol::Net::Curl));
        fetch();
    },
});

sub fetch {
    my $ua = LWP::UserAgent->new;
    for (1 .. 1000) {
        # small file
        $ua->get(qq(http://localhost/manual/index.html?$_));
        # average file
        $ua->get(qq(http://localhost/manual/en/mod/mod_log_config.html?$_));
        # big file
        $ua->get(qq(http://localhost/manual/en/mod/core.html?$_));
    }
    return;
}
