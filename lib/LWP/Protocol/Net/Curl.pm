package LWP::Protocol::Net::Curl;
# ABSTRACT: the power of libcurl in the palm of your hands!

=head1 SYNOPSIS

    #!/usr/bin/env perl;
    use common::sense;

    use LWP::Protocol::Net::Curl;
    use WWW::Mechanize;

    ...

=head1 DESCRIPTION

Drop-in replacement for L<LWP>, L<WWW::Mechanize> and their derivatives to use L<Net::Curl> as a backend.

Advantages:

=for :list
* support ftp/ftps/http/https/sftp/scp/SOCKS protocols out-of-box (if your L<libcurl|http://curl.haxx.se/> is compiled to support them)
* lightning-fast L<HTTP compression|https://en.wikipedia.org/wiki/Http_compression>
* 100% compatible with both L<LWP> and L<WWW::Mechanize> test suites
* lower CPU/memory usage: this matters if you C<fork()> multiple downloader instances

=head1 LIBCURL INTERFACE

You may query which L<LWP> protocols are implemented through L<Net::Curl> by accessing C<@LWP::Protocol::Net::Curl::implements>.

Default L<curl_easy_setopt() options|http://curl.haxx.se/libcurl/c/curl_easy_setopt.html> can be set during initialization:

    use LWP::Protocol::Net::Curl
        encoding => '', # use HTTP compression by default
        referer => 'http://google.com/',
        verbose => 1;   # make libcurl print lots of stuff to STDERR

Options set this way have the lowest precedence.
For instance, if L<WWW::Mechanize> sets the I<Referer:> by it's own, the value you defined above won't be used.

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

sub _curlopt {
    my ($key) = @_;

    $key =~ s/^Net::Curl::Easy:://ix;
    $key =~ y/-/_/;
    $key =~ s/\W//gx;
    $key = uc $key;
    $key = qq(CURLOPT_${key}) if $key !~ /^CURLOPT_/x;

    my $const = eval {
        no strict qw(refs); ## no critic
        return *$key->();
    };
    carp qq(Invalid libcurl constant: $key) if not defined $const or $@;

    return $const;
}

sub import {
    my (undef, @args) = @_;

    if (@args) {
        my %args = @args;
        while (my ($key, $value) = each %args) {
            if (looks_like_number($key)) {
                $curlopt{$key} = $value;
            } else {
                $curlopt{_curlopt($key)} = $value;
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

    # SSL stuff, may not be compiled
    if ($request->uri->scheme =~ /s$/ix) {
        $easy->setopt(_curlopt(q(CAINFO))           => $self->{ua}{ssl_opts}{SSL_ca_file});
        $easy->setopt(_curlopt(q(CAPATH))           => $self->{ua}{ssl_opts}{SSL_ca_path});
        $easy->setopt(_curlopt(q(SSL_VERIFYHOST))   => $self->{ua}{ssl_opts}{verify_hostname});
    }

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
    } elsif ($method eq q(DELETE)) {
        $easy->setopt(CURLOPT_CUSTOMREQUEST ,=> $method);
    } elsif ($method eq q(PUT)) {
        $easy->setopt(CURLOPT_UPLOAD        ,=> 1);
        $easy->setopt(CURLOPT_READDATA      ,=> $request->content);
        $easy->setopt(CURLOPT_INFILESIZE    ,=> length $request->content);
        $easy->pushopt(CURLOPT_HTTPHEADER   ,=> [qq[Expect:]]); # mimic LWP behavior
    } else {
        return HTTP::Response->new(
            &HTTP::Status::RC_BAD_REQUEST,
            qq(Bad method '$_')
        );
    }

    $request->headers->scan(sub {
        my ($key, $value) = @_;

        # stolen from LWP::Protocol::http
        $key =~ s/^://x;
        $value =~ s/\n/ /gx;

        if ($key =~ /^accept-encoding$/ix) {
            my @encoding =
                map { /^(?:x-)?(deflate|gzip|identity)$/ix ? lc $1 : () }
                split /\s*,\s*/x, $value;

            if (@encoding) {
                ++$encoding;
                $easy->setopt(CURLOPT_ENCODING ,=> join(q(, ) => @encoding));
            }
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

=head1 TODO

=for :list
* better implementation for non-HTTP protocols
* more tests
* test exotic LWP usage cases
* non-blocking version

=head1 SEE ALSO

=for :list
* L<LWP::Protocol::GHTTP> - used as a reference
* L<LWP::Protocol::AnyEvent::http> - another reference
* L<Net::Curl> - backend for this module
* L<LWP::Curl> - provides L<LWP::UserAgent>-compatible API for libcurl

=cut

1;
