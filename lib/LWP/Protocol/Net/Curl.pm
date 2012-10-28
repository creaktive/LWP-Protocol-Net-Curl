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
* support ftp/ftps/http/https/sftp/scp protocols out-of-box (secure layer require L<libcurl|http://curl.haxx.se/> to be compiled with TLS/SSL/libssh2 support)
* support SOCKS4/5 proxy out-of-box
* connection persistence and DNS cache (independent from L<LWP::ConnCache>)
* lightning-fast L<HTTP compression|https://en.wikipedia.org/wiki/Http_compression> and redirection
* lower CPU usage: this matters if you C<fork()> multiple downloader instances
* at last but not least: B<100% compatible> with both L<LWP> and L<WWW::Mechanize> test suites!

=head1 LIBCURL INTERFACE

You may query which L<LWP> protocols are implemented through L<Net::Curl> by accessing C<@LWP::Protocol::Net::Curl::implements>.

Default L<curl_easy_setopt() options|http://curl.haxx.se/libcurl/c/curl_easy_setopt.html> can be set during initialization:

    use LWP::Protocol::Net::Curl
        encoding    => '',  # use HTTP compression by default
        referer     => 'http://google.com/',
        verbose     => 1;   # make libcurl print lots of stuff to STDERR

Options set this way have the lowest precedence.
For instance, if L<WWW::Mechanize> sets the I<Referer:> by it's own, the value you defined above won't be used.

=head1 DEBUGGING

Quickly enable libcurl I<verbose> mode via C<PERL5OPT> environment variable:

    PERL5OPT=-MLWP::Protocol::Net::Curl=verbose,1 perl your-script.pl

B<Bonus:> it works even if you don't include the C<use LWP::Protocol::Net::Curl> line!

=cut

use strict;
use utf8;
use warnings qw(all);

use base qw(LWP::Protocol);

use Carp qw(carp);
use HTTP::Date;
use IO::Handle;
use LWP::UserAgent;
use Net::Curl::Easy qw(:constants);
use Net::Curl::Multi qw(:constants);
use Net::Curl::Share qw(:constants);
use Scalar::Util qw(looks_like_number);

# VERSION

our @implements =
    sort grep { defined }
        @{ { map { ($_)x2 } @{Net::Curl::version_info->{protocols}} } }
        {qw{ftp ftps http https sftp scp}};

LWP::Protocol::implementor($_ => __PACKAGE__)
    for @implements;

our %curlopt;

{
    no strict qw(refs);         ## no critic
    no warnings qw(redefine);   ## no critic

    *{'LWP::UserAgent::progress'} = sub {};
}

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

    my $ua = $self->{ua};
    if (q(Net::Curl::Multi) ne ref $ua->{curl_multi}) {
        $ua->{curl_multi} = Net::Curl::Multi->new;
        $ua->{curl_share} = Net::Curl::Share->new;
        $ua->{curl_share}->setopt(CURLSHOPT_SHARE ,=> CURL_LOCK_DATA_COOKIE);
        $ua->{curl_share}->setopt(CURLSHOPT_SHARE ,=> CURL_LOCK_DATA_DNS);
        eval { $ua->{curl_share}->setopt(CURLSHOPT_SHARE ,=> CURL_LOCK_DATA_SSL_SESSION) };
    }

    my $data = '';
    my $header = '';
    my $writedata = \$data;

    if (ref($arg) eq '' and $arg) {
        # will die() later
        open my ($fh), q(+>:raw), $arg; ## no critic
        $fh->autoflush(1);
        $writedata = $fh;
    }

    my $easy = Net::Curl::Easy->new;
    $ua->{curl_multi}->add_handle($easy);

    my $encoding = 0;
    while (my ($key, $value) = each %curlopt) {
        ++$encoding if $key == CURLOPT_ENCODING;
        $easy->setopt($key, $value);
    }

    # SSL stuff, may not be compiled
    if ($request->uri->scheme =~ /s$/ix) {
        $easy->setopt(_curlopt(q(CAINFO))           => $ua->{ssl_opts}{SSL_ca_file});
        $easy->setopt(_curlopt(q(CAPATH))           => $ua->{ssl_opts}{SSL_ca_path});
        $easy->setopt(_curlopt(q(SSL_VERIFYHOST))   => $ua->{ssl_opts}{verify_hostname});
    }

    $easy->setopt(CURLOPT_BUFFERSIZE        ,=> $size);
    $easy->setopt(CURLOPT_FILETIME          ,=> 1);
    $easy->setopt(CURLOPT_INTERFACE         ,=> $ua->local_address);
    $easy->setopt(CURLOPT_MAXFILESIZE       ,=> $ua->max_size);
    $easy->setopt(CURLOPT_NOPROGRESS        ,=> not $ua->show_progress);
    $easy->setopt(CURLOPT_NOPROXY           ,=> join(q(,) => @{$ua->{no_proxy}}));
    $easy->setopt(CURLOPT_PROXY             ,=> $proxy);
    $easy->setopt(CURLOPT_SHARE             ,=> $ua->{curl_share});
    $easy->setopt(CURLOPT_TIMEOUT           ,=> $timeout);
    $easy->setopt(CURLOPT_URL               ,=> $request->uri);
    $easy->setopt(CURLOPT_WRITEDATA         ,=> $writedata);
    $easy->setopt(CURLOPT_WRITEHEADER       ,=> \$header);

    my $method = uc $request->method;
    if ($method eq q(GET)) {
        $easy->setopt(CURLOPT_HTTPGET       ,=> 1);
    } elsif ($method eq q(POST)) {
        $easy->setopt(CURLOPT_POSTFIELDS    ,=> $request->content);
    } elsif ($method eq q(HEAD)) {
        $easy->setopt(CURLOPT_NOBODY        ,=> 1);
    } elsif ($method eq q(DELETE)) {
        $easy->setopt(CURLOPT_CUSTOMREQUEST ,=> $method);
    } elsif ($method eq q(PUT)) {
        $easy->setopt(CURLOPT_UPLOAD        ,=> 1);
        $easy->setopt(CURLOPT_READDATA      ,=> $request->content);
        $easy->setopt(CURLOPT_INFILESIZE    ,=> length $request->content);
    } else {
        return HTTP::Response->new(
            &HTTP::Status::RC_BAD_REQUEST,
            qq(Bad method '$method')
        );
    }

    # handle redirects internally (except POST, greatly fsck'd up by IIS servers)
    if ($method ne q(POST) and grep { $method eq uc } @{$ua->requests_redirectable}) {
        $easy->setopt(CURLOPT_AUTOREFERER   ,=> 1);
        $easy->setopt(CURLOPT_FOLLOWLOCATION,=> 1);
        $easy->setopt(CURLOPT_MAXREDIRS     ,=> $ua->max_redirect);
    } else {
        $easy->setopt(CURLOPT_FOLLOWLOCATION,=> 0);
    }

    $request->headers->scan(sub {
        my ($key, $value) = @_;

        # stolen from LWP::Protocol::http
        $key =~ s/^://x;
        $value =~ s/\n/ /gx if defined $value;

        if ($key =~ /^accept-encoding$/ix) {
            my @encoding =
                map { /^(?:x-)?(deflate|gzip|identity)$/ix ? lc $1 : () }
                split /\s*,\s*/x, $value;

            if (@encoding) {
                ++$encoding;
                $easy->setopt(CURLOPT_ENCODING  ,=> join(q(,) => @encoding));
            }
        } elsif ($key =~ /^user-agent$/ix and $value eq $ua->_agent) {
            $easy->setopt(CURLOPT_USERAGENT     ,=> $ua->_agent . ' ' . Net::Curl::version);
        } else {
            $easy->pushopt(CURLOPT_HTTPHEADER   ,=> [qq[$key: $value]]);
        }
    });

    my $status = eval { $easy->perform; 0 };
    my $error = looks_like_number($@) ? 0 + $@ : 0;
    $ua->{curl_multi}->remove_handle($easy);
    if ($error == CURLE_TOO_MANY_REDIRECTS) {
        # will return the last request
    } elsif (not defined $status or $error) {
        return HTTP::Response->new(
            &HTTP::Status::RC_BAD_REQUEST,
            Net::Curl::Easy::strerror($error)
        );
    }

    my $response;
    if ($request->uri->scheme =~ /^https?$/ix) {
        my $previous = undef;
        my @header = split /(?:\015\012?|\012\015){2}/sx, $header;
        for my $h (@header) {
            $response = HTTP::Response->parse($h);
            my $msg = defined $response->message ? $response->message : '';
            $msg =~ s/^\s+|\s+$//gsx;
            $response->message($msg);

            $response->previous($previous);
            $previous = $response;
        }
    } else {
        $response = HTTP::Response->new(&HTTP::Status::RC_OK);
    }
    $response->request($request);

    my $time = $easy->getinfo(CURLINFO_FILETIME);
    $response->headers->header(last_modified => time2str($time))
        if $time > 0;

    undef $easy;

    # handle decoded_content() & direct file write
    if (q(GLOB) eq ref $writedata) {
        $writedata->sync;
    } elsif ($encoding) {
        $response->headers->header(content_encoding => q(identity));
        $response->headers->header(content_length   => length $data);
    }

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
