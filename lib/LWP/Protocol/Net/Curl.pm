package LWP::Protocol::Net::Curl;
# ABSTRACT: the power of libcurl in the palm of your hands!

=head1 SYNOPSIS

    #!/usr/bin/env perl;
    use common::sense;

    use LWP::Protocol::Net::Curl;
    use WWW::Mechanize;

    ...

=head1 DESCRIPTION

Drop-in replacement for L<LWP>, L<WWW::Mechanize> & derivatives to use L<Net::Curl> as a backend.

Advantages:

=for :list
* support ftp/ftps/http/https/sftp/scp/SOCKS protocols out-of-box (if your L<libcurl|http://curl.haxx.se/> is compiled to support them)
* lightning-fast L<HTTP compression|https://en.wikipedia.org/wiki/Http_compression>
* 100% compatible with L<WWW::Mechanize> test suite
* lower CPU/memory usage: this matters if you C<fork()> multiple downloader instances

=cut

use strict;
use utf8;
use warnings qw(all);

use base qw(LWP::Protocol);

use Carp qw(carp);
use HTTP::Date;
use Net::Curl::Easy qw(:constants);
use Scalar::Util qw(looks_like_number);

# VERSION

our @implements =
    sort grep { defined }
        @{ { map { ($_)x2 } @{Net::Curl::version_info->{protocols}} } }
        {qw{ftp ftps http https sftp scp}};

LWP::Protocol::implementor($_ => __PACKAGE__)
    for @implements;

our %curlopt;

=for Pod::Coverage
import
request
=cut

sub import {
    my (undef, @args) = @_;

    if (@args) {
        my %args = @args;
        while (my ($key, $value) = each %args) {
            if (looks_like_number($key)) {
                $curlopt{$key} = $value;
            } else {
                $key =~ s/^Net::Curl::Easy:://ix;
                $key =~ y/-/_/;
                $key =~ s/\W//gx;
                $key = uc $key;
                $key = qq(CURLOPT_${key}) if $key !~ /^CURLOPT_/x;

                eval {
                    no strict qw(refs); ## no critic
                    $curlopt{*$key->()} = $value;
                };
                carp qq(Invalid libcurl constant: $key) if $@;
            }
        }
    }

    return;
}

sub request {
    my ($self, $request, $proxy, $arg, $size, $timeout) = @_;

    my $data = '';
    my $header = '';
    my $easy = Net::Curl::Easy->new;

    my $encoding = 0;
    while (my ($key, $value) = each %curlopt) {
        ++$encoding if $key == CURLOPT_ENCODING;
        $easy->setopt($key, $value);
    }

    $easy->setopt(CURLOPT_BUFFERSIZE        ,=> $size)
        if defined $size and $size;
    $easy->setopt(CURLOPT_TIMEOUT           ,=> $timeout)
        if defined $timeout and $timeout;

    #$easy->setopt(CURLOPT_NOPROGRESS        ,=> 0);
    #$easy->setopt(CURLOPT_PROGRESSFUNCTION  ,=> sub {});

    $easy->setopt(CURLOPT_FILETIME          ,=> 1);
    $easy->setopt(CURLOPT_FOLLOWLOCATION    ,=> 0);
    $easy->setopt(CURLOPT_PROXY             ,=> ref($proxy) =~ /^URI\b/x ? $proxy->as_string : '');
    $easy->setopt(CURLOPT_URL               ,=> $request->uri);
    $easy->setopt(CURLOPT_WRITEDATA         ,=> \$data);
    $easy->setopt(CURLOPT_WRITEHEADER       ,=> \$header);

    my $method = uc $request->method;
    if ($method eq q(GET)) {
        $easy->setopt(CURLOPT_HTTPGET   ,=> 1);
    } elsif ($method eq q(POST)) {
        $easy->setopt(CURLOPT_POSTFIELDS,=> $request->content);
    } elsif ($method eq q(HEAD)) {
        $easy->setopt(CURLOPT_NOBODY    ,=> 1);
    } else {
        return HTTP::Response->new(
            &HTTP::Status::RC_BAD_REQUEST,
            qq(Bad method '$_')
        );
    }

    $request->headers->scan(sub {
        my ($key, $value) = @_;
        if ($key =~ /^accept-encoding$/ix) {
            my @encoding =
                map { /^(?:x-)?(deflate|gzip|identity)$/ix ? lc $1 : () }
                split /\s*,\s*/x, $value;

            @encoding
                and ++$encoding
                and $easy->setopt(CURLOPT_ENCODING ,=> join(q(, ) => @encoding));
        } else {
            $easy->pushopt(CURLOPT_HTTPHEADER ,=> [qq[$key: $value]]);
        }
    });

    my $status = eval { $easy->perform; 0 };
    if (not defined $status or $@) {
        return HTTP::Response->new(
            &HTTP::Status::RC_BAD_REQUEST,
            qq($@)
        );
    }

    my $response = HTTP::Response->parse(
        $request->uri->scheme =~ /^https?$/ix
            ? $header
            : qq(200 OK\n\n)
    );
    $response->request($request);

    my $msg = defined $response->message ? $response->message : '';
    $msg =~ s/^\s+|\s+$//gsx;
    $response->message($msg);

    # handle decoded_content()
    if ($encoding) {
        $response->headers->header(content_encoding => q(identity));
        $response->headers->header(content_length => length $data);
    }

    my $time = $easy->getinfo(CURLINFO_FILETIME);
    $response->headers->header(last_modified => time2str($time))
        if $time > 0;

    return $self->collect_once($arg, $response, $data);
}

=head1 SEE ALSO

=for :list
* L<LWP::Protocol::GHTTP> - used as a reference
* L<LWP::Protocol::AnyEvent::http> - another reference
* L<Net::Curl> - backend for this module
* L<LWP::Curl> - provides L<LWP::UserAgent>-compatible API for libcurl

=cut

1;
