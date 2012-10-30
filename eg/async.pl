#!/usr/bin/env perl
use common::sense;

#=for comment
{
    package LWP::Protocol::Net::Curl;
    use Coro::Select qw(select);
    use LWP::Protocol::Net::Curl
        encoding    => '',
        verbose     => 1;
}
#=cut

use Coro;
use LWP::UserAgent;

my $ua = LWP::UserAgent->new(
    timeout     => 10,
);

my @pids = map {
    async {
        $ua->get(shift);
    } $_
} qw{
    http://google.com
    http://facebook.com
    http://youtube.com
    http://yahoo.com
    http://baidu.com
    http://wikipedia.org
    http://live.com
    http://twitter.com
    http://qq.com
    http://amazon.com
};

$_->join for @pids;
