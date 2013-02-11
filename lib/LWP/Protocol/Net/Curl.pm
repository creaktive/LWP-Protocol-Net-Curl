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
* asynchronous threading via L<Coro::Select> (see F<eg/async.pl>)
* at last but not least: B<100% compatible> with both L<LWP> and L<WWW::Mechanize> test suites!

=head1 LIBCURL INTERFACE

You may query which L<LWP> protocols are implemented through L<Net::Curl> by accessing C<@LWP::Protocol::Net::Curl::implements> or C<%LWP::Protocol::Net::Curl::implements>.

By default, B<every protocol> listed in that array will be implemented via L<LWP::Protocol::Net::Curl>.
It is possible to import only specific protocols:

    use LWP::Protocol::Net::Curl takeover => 0;
    LWP::Protocol::implementor(https => 'LWP::Protocol::Net::Curl');

The default value of C<takeover> option is I<true>, resulting in exactly the same behavior as in:

    use LWP::Protocol::Net::Curl takeover => 0;
    LWP::Protocol::implementor($_ => 'LWP::Protocol::Net::Curl')
        for @LWP::Protocol::Net::Curl::implements;

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
use Config;
use Fcntl;
use HTTP::Date;
use LWP::UserAgent;
use Net::Curl::Easy qw(:constants);
use Net::Curl::Multi qw(:constants);
use Net::Curl::Share qw(:constants);
use Scalar::Util qw(looks_like_number);

# VERSION

my %curlopt;
my $share;
unless (defined $Config{usethreads}) {
    $share = Net::Curl::Share->new({ started => time });
    $share->setopt(CURLSHOPT_SHARE ,=> CURL_LOCK_DATA_DNS);

    ## no critic (RequireCheckingReturnValueOfEval)
    eval { $share->setopt(CURLSHOPT_SHARE ,=> CURL_LOCK_DATA_SSL_SESSION) };
}

## no critic (ProhibitPackageVars)
my %protocols = map { ($_) x 2 } @{Net::Curl::version_info()->{protocols}};
our @implements =
    sort grep { defined }
        @protocols
        {qw{ftp ftps gopher http https sftp scp}};
our %implements = map { $_ => 1 } @implements;

=for Pod::Coverage
import
request
=cut

# Resolve libcurl constants by string
sub _curlopt {
    my ($key, $no_carp) = @_;
    return 0 + $key if looks_like_number($key);

    $key =~ s/^Net::Curl::Easy:://ix;
    $key =~ y/-/_/;
    $key =~ s/\W//gx;
    $key = uc $key;
    $key = qq(CURLOPT_${key}) if $key !~ /^CURL(?:M|SH)?OPT_/x;

    ## no critic (ProhibitNoStrict,ProhibitNoWarnings)
    my $const = eval {
        no strict qw(refs);
        no warnings qw(once);
        return *$key->();
    };
    carp qq(Invalid libcurl constant: $key)
        if $@
        and not defined $no_carp;

    return $const;
}

# Sugar for a common setopt() pattern
sub _setopt_ifdef {
    my ($curl, $key, $value, $no_carp) = @_;

    my $curlopt_key = _curlopt($key, $no_carp);
    $curl->setopt($curlopt_key => $value)
        if defined $curlopt_key
        and defined $value;

    return;
}

# Pre-configure the module
sub import {
    my ($class, @args) = @_;

    my $takeover = 1;
    if (@args) {
        my %args = @args;
        while (my ($key, $value) = each %args) {
            if ($key eq q(takeover)) {
                $takeover = $value;
            } else {
                my $const = _curlopt($key);
                $curlopt{$const} = $value
                    if defined $const;
            }
        }
    }

    if ($takeover) {
        LWP::Protocol::implementor($_ => $class)
            for @implements;
    }

    return;
}

# Properly setup libcurl to handle each method in a compatible way
sub _handle_method {
    my ($ua, $easy, $request) = @_;

    my $method = uc $request->method;
    my %dispatch = (
        GET => sub {
            $easy->setopt(CURLOPT_HTTPGET   ,=> 1);
        }, POST => sub {
            $easy->setopt(CURLOPT_POST      ,=> 1);
            $easy->setopt(CURLOPT_POSTFIELDS,=> $request->content);
        }, HEAD => sub {
            $easy->setopt(CURLOPT_NOBODY    ,=> 1);
        }, DELETE => sub {
            $easy->setopt(CURLOPT_CUSTOMREQUEST ,=> $method);
        }, PUT => sub {
            $easy->setopt(CURLOPT_UPLOAD    ,=> 1);
            my $buf = $request->content;
            my $off = 0;
            $easy->setopt(CURLOPT_INFILESIZE,=> length $buf);
            $easy->setopt(CURLOPT_READFUNCTION ,=> sub {
                my (undef, $maxlen) = @_;
                my $chunk = substr $buf, $off, $maxlen;
                $off += length $chunk;
                return \$chunk;
            });
        },
    );

    my $method_ref = $dispatch{$method};
    if (defined $method_ref) {
        $method_ref->();
    } else {
        ## no critic (RequireCarping)
        die HTTP::Response->new(
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

    return $method;
}

# Compatibilize request headers
sub _fix_headers {
    my ($ua, $easy, $key, $value) = @_;

    return 0 unless defined $value;

    # stolen from LWP::Protocol::http
    $key =~ s/^://x;
    $value =~ s/\n/ /gx;

    my $encoding = 0;
    if ($key =~ /^accept-encoding$/ix) {
        my @encoding =
            map { /^(?:x-)?(deflate|gzip|identity)$/ix ? lc $1 : () }
            split /\s*,\s*/x, $value;

        if (@encoding) {
            ++$encoding;
            $easy->setopt(CURLOPT_ENCODING  ,=> join(q(,) => @encoding));
        }
    } elsif ($key =~ /^user-agent$/ix) {
        # While we try our best to look like LWP on the client-side,
        # it's *definitely* different on the server-site!
        # I guess it would be nice to introduce ourselves in a polite way.
        $value =~ s/\b(\Q@{[ $ua->_agent ]}\E)\b/qq($1 ) . Net::Curl::version()/egx;
        $easy->setopt(CURLOPT_USERAGENT     ,=> $value);
    } else {
        $easy->pushopt(CURLOPT_HTTPHEADER   ,=> [qq[$key: $value]]);
    }

    return $encoding;
}

# Wrap libcurl perform() in a non-blocking way
sub _perform_loop {
    my ($multi) = @_;

    my $running = 0;
    do {
        my ($r, $w, $e) = $multi->fdset;
        my $timeout = $multi->timeout;
        select($r, $w, $e, $timeout / 1000)
            if $timeout > 9;

        $running = $multi->perform;
        while (my (undef, $easy, $result) = $multi->info_read) {
            $multi->remove_handle($easy);
            if ($result == CURLE_TOO_MANY_REDIRECTS) {
                # will return the last request
            } elsif ($result) {
                ## no critic (RequireCarping)
                die HTTP::Response->new(
                    &HTTP::Status::RC_BAD_REQUEST,
                    qq($result),
                );
            }
        }
    } while ($running);

    return $running;
}

## no critic (ProhibitManyArgs)
sub request {
    my ($self, $request, $proxy, $arg, $size, $timeout) = @_;

    my $ua = $self->{ua};
    unless (q(Net::Curl::Multi) eq ref $ua->{curl_multi}) {
        $ua->{curl_multi} = Net::Curl::Multi->new({ def_headers => $ua->{def_headers} });

        # avoid "callback function is not set" warning
        _setopt_ifdef(
            $ua->{curl_multi},
            q(CURLMOPT_SOCKETFUNCTION) => sub { return 0 },
            1,
        );
    }

    my $data = '';
    my $header = '';
    my $writedata;

    my $easy = Net::Curl::Easy->new({ request => $request });
    $ua->{curl_multi}->add_handle($easy);

    my $previous = undef;
    my $response = HTTP::Response->new(&HTTP::Status::RC_OK);
    $response->request($request);

    $easy->setopt(CURLOPT_HEADERFUNCTION ,=> sub {
        my (undef, $line) = @_;
        $header .= $line;

        # I hope only HTTP sends "empty line" as delimiters
        if ($line =~ /^\s*$/sx) {
            $response = HTTP::Response->parse($header);
            my $msg = $response->message;
            $msg = '' unless defined $msg;
            $msg =~ s/^\s+|\s+$//gsx;
            $response->message($msg);

            $response->request($request);
            $response->previous($previous) if defined $previous;
            $previous = $response;

            $header = '';
        }

        return length $line;
    });

    if (q(CODE) eq ref $arg) {
        $easy->setopt(CURLOPT_WRITEFUNCTION ,=> sub {
            my (undef, $chunk) = @_;
            $arg->($chunk, $response, $self);
            return length $chunk;
        });
        $writedata = undef;
    } elsif (defined $arg) {
        # will die() later
        sysopen $writedata, $arg, O_CREAT | O_NONBLOCK | O_WRONLY;
        binmode $writedata;
    } else {
        $writedata = \$data;
    }

    my $encoding = 0;
    while (my ($key, $value) = each %curlopt) {
        ++$encoding if $key == CURLOPT_ENCODING;
        $easy->setopt($key, $value);
    }

    # SSL stuff, may not be compiled
    if ($request->uri->scheme =~ /s$/ix) {
        _setopt_ifdef($easy, CAINFO         => $ua->{ssl_opts}{SSL_ca_file});
        _setopt_ifdef($easy, CAPATH         => $ua->{ssl_opts}{SSL_ca_path});

        # fixes a security flaw denied by libcurl v7.28.1
        _setopt_ifdef($easy, SSL_VERIFYHOST => (!!$ua->{ssl_opts}{verify_hostname}) << 1);
    }

    $easy->setopt(CURLOPT_FILETIME          ,=> 1);
    $easy->setopt(CURLOPT_URL               ,=> $request->uri);
    _setopt_ifdef($easy, CURLOPT_BUFFERSIZE ,=> $size);
    _setopt_ifdef($easy, CURLOPT_INTERFACE  ,=> $ua->local_address);
    _setopt_ifdef($easy, CURLOPT_MAXFILESIZE,=> $ua->max_size);
    _setopt_ifdef($easy, q(CURLOPT_NOPROXY)  => join(q(,) => @{$ua->{no_proxy}}), 1);
    _setopt_ifdef($easy, CURLOPT_PROXY      ,=> $proxy);
    _setopt_ifdef($easy, CURLOPT_SHARE      ,=> $share);
    _setopt_ifdef($easy, CURLOPT_TIMEOUT    ,=> $timeout);
    _setopt_ifdef($easy, CURLOPT_WRITEDATA  ,=> $writedata);

    if ($ua->show_progress) {
        $easy->setopt(CURLOPT_NOPROGRESS        ,=> 0);
        $easy->setopt(CURLOPT_PROGRESSFUNCTION  ,=> sub {
            my (undef, $dltotal, $dlnow) = @_;
            $ua->progress($dltotal ? $dlnow / $dltotal : q(tick));
            return 0;
        });
    }

    _handle_method($ua, $easy, $request);

    $request->headers->scan(sub { $encoding += _fix_headers($ua, $easy, @_) });

    _perform_loop($ua->{curl_multi});

    $response->code($easy->getinfo(CURLINFO_RESPONSE_CODE) || 200);

    my $time = $easy->getinfo(CURLINFO_FILETIME);
    $response->headers->header(last_modified => time2str($time))
        if $time > 0;

    # handle decoded_content() & direct file write
    if (q(GLOB) eq ref $writedata) {
        close $writedata;
        # avoid truncate by collect()
        $arg = undef;
    } elsif ($encoding) {
        $response->headers->header(content_encoding => q(identity));
    }

    return $self->collect_once($arg, $response, $data);
}

=head1 TODO

=for :list
* better implementation for non-HTTP protocols
* more tests
* expose the inner guts of libcurl while handling encoding/redirects internally
* revise L<Net::Curl::Multi> "event loop" code

=head1 BUGS

=for :list
* sometimes still complains about I<Attempt to free unreferenced scalar: SV 0xdeadbeef during global destruction.>
* in "async mode", each L<LWP::UserAgent> instance "blocks" until all requests finish
* parallel requests via L<Coro::Select> are B<very inefficient>; consider using L<YADA> if you're into event-driven parallel user agents
* L<Net::Curl::Share> support is disabled on threaded Perl builds

=head1 SEE ALSO

=for :list
* L<LWP::Protocol::GHTTP> - used as a reference for L<LWP::Protocol> implementation
* L<LWP::Protocol::AnyEvent::http> - another L<LWP::Protocol> reference
* L<YADA> - L<Net::Curl> usage reference
* L<Net::Curl> - backend for this module
* L<LWP::Curl> - provides L<LWP::UserAgent>-compatible API via L<WWW::Curl>

=cut

1;
