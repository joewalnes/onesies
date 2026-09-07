#!/usr/bin/perl
# tuner-knee.pl - does the connection tuner overshoot the throughput knee?
#
# Reproduces, deterministically and locally, the failure measured on the
# one-core droplet: on a CPU-bound client, aggregate throughput FALLS as
# connections rise, and a tuner that grows faster than it shrinks ratchets the
# pool far above the optimum and stays there for the whole download.
#
# The origin here serves ranges at a per-connection rate of BASE/n**ALPHA where
# n is the number of concurrent transfers, so aggregate throughput is
# BASE*n**(1-ALPHA) - strictly decreasing in n for ALPHA > 1. The best possible
# pool size is therefore 1, and any pool the tuner settles on above that is
# measurable overshoot.
#
# A stub `sysctl` is placed first on PATH so cpu_count() reports 1 and bigcurl
# opens the small pool a one-core box gets. Without that the mac opens 32 and
# the climb this test is about cannot happen at all.
#
#   ./tuner-knee.pl /path/to/bigcurl [more/bigcurl ...]
#
# Prints, per build, the pool sizes visited and the throughput achieved.
#
# HOW FAITHFUL IS THIS? Calibrated once, against the one-core droplet pulling
# 1 GB from Hetzner over the tailnet:
#
#   * It reproduces the shape of the failure. The droplet's pool trace is
#     4 -> 12 -> 20 and stays high; this fixture reproduces 4 -> 12 -> 20.
#   * It correctly predicted a NEGATIVE. A first attempt that added a per-size
#     speed memory without the ramp modelled here looked like a win on the
#     unramped fixture (+9%) and was a no-op on the droplet (44.5 -> 44.8 MB/s).
#     Adding $RAMP made the fixture agree with the hardware: both said no-op.
#
# WHERE IT DIVERGES - do not quote its percentages as hardware numbers:
#
#   * Magnitudes are not transferable. A change worth +7% here measured +25% on
#     the droplet. Use it to decide DIRECTION, then confirm on real hardware.
#   * The real bottleneck is CPU contention with a userspace-WireGuard daemon on
#     a shared core. Here it is an arithmetic rate law, BASE/n**ALPHA, so there
#     is no scheduler, no syscall cost and no interference from bigcurl's own
#     process count - a change that wins by using fewer PROCESSES at the same
#     connection count would show up as nothing here.
#   * There is no packet loss and no retransmission, so it says NOTHING about
#     the lossy cells where more connections genuinely win. A tuner change that
#     looks good here can still regress those badly - one measured here did,
#     by 20-28% in the netem lab. Always run the netem grid as well.
#   * $RAMP is a linear ramp, not TCP slow start; it reproduces the confound
#     without reproducing congestion control.
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies

use strict;
use warnings;
use Socket;
use Time::HiRes qw(time sleep);
use File::Path qw(rmtree);

my @builds = @ARGV;
die "usage: tuner-knee.pl <bigcurl> [bigcurl2 ...]\n" unless @builds;

my $SIZE  = 128 * 1024 * 1024;
my $BASE  = 12 * 1024 * 1024;   # bytes/s delivered when exactly one transfer runs
my $ALPHA = 1.35;               # >1 means more connections = less aggregate
my $TICK  = 0.02;
my $RAMP  = 1.5;                # seconds for a new connection to reach full rate
                                # (TCP slow-start analogue; see the note below)

my $work = "/tmp/tunerknee.$$";
mkdir $work or die "mkdir $work: $!";
my $src = "$work/big.bin";
open(my $sf, '>', $src) or die $!;
binmode $sf;
# Deterministic, incompressible-enough content; content only has to be stable.
my $chunk = pack('L*', map { ($_ * 2654435761) & 0xFFFFFFFF } 0 .. (262144/4 - 1));
print $sf $chunk for 1 .. ($SIZE / length($chunk));
close $sf;
my $want = `shasum -a 256 '$src' 2>/dev/null || sha256sum '$src'`;
($want) = $want =~ /^(\w{64})/;

# stub sysctl so cpu_count() == 1
mkdir "$work/bin";
open(my $st, '>', "$work/bin/sysctl") or die $!;
print $st "#!/bin/sh\necho 1\n";
close $st;
chmod 0755, "$work/bin/sysctl";

# ---- origin -------------------------------------------------------------
socket(my $srv, PF_INET, SOCK_STREAM, getprotobyname('tcp')) or die "socket: $!";
setsockopt($srv, SOL_SOCKET, SO_REUSEADDR, 1);
bind($srv, sockaddr_in(0, INADDR_LOOPBACK)) or die "bind: $!";
listen($srv, 128) or die "listen: $!";
my $port = (sockaddr_in(getsockname($srv)))[0];

my $spid = fork();
die "fork: $!" unless defined $spid;
if ($spid == 0) {
    $SIG{PIPE} = 'IGNORE';
    open(my $data, '<', $src) or die $!;
    binmode $data;
    my (%conn, %buf);
    my $sel = '';
    vec($sel, fileno($srv), 1) = 1;
    my $last = time();
    while (1) {
        my $r = $sel;
        my $n = select($r, undef, undef, $TICK);
        if (vec($r, fileno($srv), 1)) {
            if (accept(my $c, $srv)) {
                my $fd = fileno($c);
                $conn{$fd} = { sock => $c, state => 'req', off => 0, end => -1, credit => 0 };
                $buf{$fd} = '';
                vec($sel, $fd, 1) = 1;
            }
        }
        for my $fd (keys %conn) {
            my $c = $conn{$fd};
            next unless $c->{state} eq 'req' && vec($r, $fd, 1);
            my $got = sysread($c->{sock}, my $b, 8192);
            if (!defined $got || $got == 0) { close $c->{sock}; vec($sel,$fd,1)=0; delete $conn{$fd}; next }
            $buf{$fd} .= $b;
            next unless $buf{$fd} =~ /\r\n\r\n/;
            my $req = $buf{$fd};
            my ($s, $e) = (0, $SIZE - 1);
            if ($req =~ /^Range:\s*bytes=(\d+)-(\d*)/mi) { $s = $1; $e = $2 ne '' ? $2 : $SIZE - 1 }
            $e = $SIZE - 1 if $e > $SIZE - 1;
            my $len = $e - $s + 1;
            my $head;
            if ($req =~ m{^HEAD }) {
                $head = "HTTP/1.1 200 OK\r\nContent-Length: $SIZE\r\nAccept-Ranges: bytes\r\n\r\n";
                syswrite($c->{sock}, $head);
                close $c->{sock}; vec($sel,$fd,1)=0; delete $conn{$fd}; next;
            }
            $head = $req =~ /^Range:/mi
                ? "HTTP/1.1 206 Partial Content\r\nContent-Length: $len\r\n"
                  . "Content-Range: bytes $s-$e/$SIZE\r\nAccept-Ranges: bytes\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: $SIZE\r\nAccept-Ranges: bytes\r\n\r\n";
            syswrite($c->{sock}, $head);
            @{$c}{qw(state off end)} = ('body', $s, $e);
            vec($sel, $fd, 1) = 0;   # we drive writes on the clock, not on readiness
        }
        # rate-limited body writes
        my $now = time();
        my $dt  = $now - $last;
        $last = $now;
        my @act = grep { $conn{$_}{state} eq 'body' } keys %conn;
        my $act = scalar(@act) || 1;
        my $per = $BASE / ($act ** $ALPHA);          # bytes/s per connection
        for my $fd (@act) {
            my $c = $conn{$fd};
            # AIDEV-NOTE: Each connection ramps to full rate over $RAMP seconds,
            # standing in for TCP slow start. Without this the fixture cannot
            # exhibit the confound that actually defeats a per-size speed
            # memory on a real link: a window measured just after the pool grew
            # is still ramping, so it reads LOW at small sizes and the tuner
            # concludes that growing helped when it did not.
            $c->{t0} = $now unless $c->{t0};
            my $ramp = ($now - $c->{t0}) / $RAMP;
            $ramp = 1 if $ramp > 1;
            $c->{credit} += $per * $ramp * $dt;
            next if $c->{credit} < 4096;
            my $take = int($c->{credit});
            my $left = $c->{end} - $c->{off} + 1;
            $take = $left if $take > $left;
            seek($data, $c->{off}, 0);
            read($data, my $out, $take);
            my $w = syswrite($c->{sock}, $out);
            if (!defined $w) { close $c->{sock}; delete $conn{$fd}; next }
            $c->{off} += $w; $c->{credit} -= $w;
            if ($c->{off} > $c->{end}) {
                close $c->{sock}; delete $conn{$fd};
            }
        }
    }
    exit 0;
}

sleep 0.3;
my $url = "http://127.0.0.1:$port/big.bin";
printf("origin: %s  size=%dMB  base=%dMB/s alpha=%s (aggregate falls as conns rise)\n",
       $url, $SIZE/1048576, $BASE/1048576, $ALPHA);
printf("%-26s %8s %9s %8s %8s  %s\n", 'build', 'secs', 'MB/s', 'ok', 'maxconn', 'pool sizes visited');

my $rc = 0;
for my $b (@builds) {
    my $out = "$work/dl.bin";
    unlink $out, "$out.part", "$out.part.state";
    my $log = "$work/log.txt";
    my $t0 = time();
    local $ENV{PATH} = "$work/bin:$ENV{PATH}";
    system("'$b' -l -o '$out' '$url' > '$log' 2>&1");
    my $el = time() - $t0;
    my $got = `shasum -a 256 '$out' 2>/dev/null || sha256sum '$out'`;
    ($got) = ($got // '') =~ /^(\w{64})/;
    my $ok = (defined $got && defined $want && $got eq $want) ? 'yes' : 'NO';
    open(my $lf, '<', $log);
    my @c;
    while (<$lf>) { push @c, $1 while /"conns":(\d+)/g }
    close $lf;
    my @seq; my $prev = -1;
    for my $x (@c) { push @seq, $x if $x != $prev; $prev = $x }
    my $max = 0; for (@c) { $max = $_ if $_ > $max }
    # AIDEV-NOTE: An instrument that reads nothing must SAY so. A run that
    # exits early - wrong path, origin never came up, bigcurl skipping an
    # output file that already exists - produces an empty pool trace, and an
    # empty trace printed as a blank column is indistinguishable from "the
    # tuner never moved", which is a result. Refuse to report instead.
    if (!@c) {
        printf("%-26s %8s %9s %8s %8s  %s\n", (split m{/}, $b)[-1],
               '-', '-', $ok, 0, 'NO PROGRESS EVENTS - instrument did not reach its subject');
        print "  --- log ---\n";
        if (open(my $d, '<', $log)) { print "  $_" for <$d>; close $d }
        $rc = 2;
        next;
    }
    printf("%-26s %8.2f %9.2f %8s %8d  %s\n", (split m{/}, $b)[-1], $el,
           ($SIZE/1048576)/$el, $ok, $max, join(' ', @seq[0 .. ($#seq > 14 ? 14 : $#seq)]));
    if ($ok eq "NO") { $rc = 1; print "  --- log ---\n"; open(my $d,"<",$log); print "  $_" for <$d>; close $d; }
}

kill('KILL', $spid); waitpid($spid, 0);
rmtree($work);
exit $rc;
