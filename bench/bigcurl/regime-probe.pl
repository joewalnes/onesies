#!/usr/bin/env perl
#
# regime-probe.pl - measure whether a link's impairment is PER-CONNECTION or a
# SHARED BOTTLENECK, using plain curl only. Independent of bigcurl: this exists
# to establish whether the physical signal exists at all, before asking whether
# bigcurl could observe it.
#
# For each rep it fires N simultaneous HTTP range requests of equal size at one
# origin and records, per connection, curl's own timing. From those it derives:
#
#   spread_cv   stddev/mean of per-connection transfer rate   (S6)
#   straggler   max/median of per-connection transfer time    (S7)
#   ttfb_cv     stddev/mean of per-connection time_starttransfer
#   agg_mbs     summed transfer rate of the N connections
#
# and, with --conns 1 also run, speedup = agg_mbs(N) / agg_mbs(1)  (S8).
#
# Loss on one TCP flow is invisible to its siblings, so a per-connection
# impairment shows large spread/straggler and a large speedup. A shared pipe
# split N ways shows small spread and a speedup near 1.
#
# Usage:
#   regime-probe.pl --url URL --span BYTES [--conns 8] [--reps 5]
#                   [--offset BYTES] [--label NAME] [--csv FILE]
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies

use strict;
use warnings;

my %opt = (conns => 8, reps => 5, span => 8 << 20, offset => 0, label => 'probe');
my @args = @ARGV;
while (@args) {
    my $a = shift @args;
    if    ($a eq '--url')    { $opt{url}    = shift @args }
    elsif ($a eq '--span')   { $opt{span}   = shift @args }
    elsif ($a eq '--conns')  { $opt{conns}  = shift @args }
    elsif ($a eq '--reps')   { $opt{reps}   = shift @args }
    elsif ($a eq '--offset') { $opt{offset} = shift @args }
    elsif ($a eq '--label')  { $opt{label}  = shift @args }
    elsif ($a eq '--csv')    { $opt{csv}    = shift @args }
    else { die "unknown arg: $a\n" }
}
die "--url required\n" unless $opt{url};
die "--conns must be >= 1\n" unless $opt{conns} >= 1;

sub mean { my @v = @_; return 0 unless @v; my $s = 0; $s += $_ for @v; return $s / scalar(@v) }
sub sd {
    my @v = @_; return 0 if scalar(@v) < 2;
    my $m = mean(@v); my $s = 0; $s += ($_ - $m) ** 2 for @v;
    return sqrt($s / (scalar(@v) - 1));
}
sub median {
    my @s = sort { $a <=> $b } @_; return 0 unless @s;
    my $n = scalar @s;
    return $n % 2 ? $s[int($n/2)] : ($s[$n/2 - 1] + $s[$n/2]) / 2;
}

# One rep: $n simultaneous range requests, each $span bytes, non-overlapping.
# Returns a hashref of derived metrics, or undef if fewer than $n connections
# returned usable timing (we never average over a partial fan-out).
sub one_rep {
    my ($n, $rep) = @_;
    my $dir = "/tmp/regime-probe.$$.$rep";
    mkdir $dir or die "mkdir $dir: $!";
    my @pids;
    for my $i (0 .. $n - 1) {
        my $lo = $opt{offset} + $i * $opt{span};
        my $hi = $lo + $opt{span} - 1;
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            # %{time_starttransfer} is TTFB; time_total-time_starttransfer is
            # the body transfer phase, which is what we want the rate of --
            # curl's own %{speed_download} folds in connect+TTFB and on a
            # 250ms-RTT link that alone would manufacture a spread.
            my @cmd = ('curl', '-sS', '-o', '/dev/null',
                       '--range', "$lo-$hi",
                       '-w', '%{size_download} %{time_starttransfer} %{time_total} %{time_connect} %{http_code}\n',
                       $opt{url});
            open(STDOUT, '>', "$dir/$i") or exit 3;
            open(STDERR, '>', "$dir/$i.err") or exit 3;
            exec { $cmd[0] } @cmd;
            exit 127;
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;

    my (@rate, @dur, @ttfb);
    my $bad = 0;
    for my $i (0 .. $n - 1) {
        my $line = '';
        if (open(my $fh, '<', "$dir/$i")) { $line = <$fh> // ''; close $fh }
        chomp $line;
        my ($size, $tstart, $ttot, $tconn, $code) = split ' ', $line;
        unless (defined $code && $code =~ /^20[06]$/ && defined $size
                && $size == $opt{span}) {
            $bad++;
            next;
        }
        my $body = $ttot - $tstart;
        if ($body <= 0.001) { $bad++; next }
        push @rate, $size / $body;
        push @dur,  $body;
        push @ttfb, $tstart - $tconn;
    }
    unlink glob("$dir/*"); rmdir $dir;

    # Fail loudly rather than reporting a metric computed from a handful of
    # survivors: a partial fan-out has a different concurrency than asked for
    # and its spread means nothing.
    if ($bad > 0) {
        warn sprintf("  rep %d (conns=%d): %d/%d connections unusable - REP DISCARDED\n",
                     $rep, $n, $bad, $n);
        return undef;
    }
    return undef unless scalar(@rate) == $n;

    my $agg = 0; $agg += $_ for @rate;
    my $med_dur = median(@dur);
    return {
        n         => $n,
        spread_cv => mean(@rate) > 0 ? sd(@rate) / mean(@rate) : 0,
        straggler => $med_dur > 0 ? (sort { $b <=> $a } @dur)[0] / $med_dur : 0,
        ttfb_cv   => mean(@ttfb) > 0 ? sd(@ttfb) / mean(@ttfb) : 0,
        agg_mbs   => $agg / 1e6,
        med_mbs   => median(@rate) / 1e6,
    };
}

my %by_conns;
for my $n ($opt{conns}, 1) {
    next if $n == 1 && $opt{conns} == 1;
    printf "== %s: concurrency %d, %d reps, %d bytes/conn ==\n",
        $opt{label}, $n, $opt{reps}, $opt{span};
    my @reps;
    for my $r (1 .. $opt{reps}) {
        my $m = one_rep($n, "$n-$r");
        next unless $m;
        push @reps, $m;
        printf "  rep %d: spread_cv=%.3f straggler=%.2f ttfb_cv=%.3f agg=%.2f MB/s\n",
            $r, $m->{spread_cv}, $m->{straggler}, $m->{ttfb_cv}, $m->{agg_mbs};
    }
    die "conns=$n: every rep was discarded - no data, refusing to report\n" unless @reps;
    $by_conns{$n} = {
        reps      => scalar @reps,
        spread_cv => median(map { $_->{spread_cv} } @reps),
        straggler => median(map { $_->{straggler} } @reps),
        ttfb_cv   => median(map { $_->{ttfb_cv} } @reps),
        agg_mbs   => median(map { $_->{agg_mbs} } @reps),
        agg_min   => (sort { $a <=> $b } map { $_->{agg_mbs} } @reps)[0],
        agg_max   => (sort { $b <=> $a } map { $_->{agg_mbs} } @reps)[0],
    };
}

my $N = $opt{conns};
my $hi = $by_conns{$N} or die "no data at concurrency $N\n";
my $speedup = ($N != 1 && $by_conns{1} && $by_conns{1}{agg_mbs} > 0)
    ? $hi->{agg_mbs} / $by_conns{1}{agg_mbs} : -1;

printf "\nRESULT %s: n=%d reps at c=%d; spread_cv=%.3f straggler=%.2f ttfb_cv=%.3f agg=%.2f MB/s (min %.2f max %.2f) speedup=%.2f\n",
    $opt{label}, $hi->{reps}, $N, $hi->{spread_cv}, $hi->{straggler},
    $hi->{ttfb_cv}, $hi->{agg_mbs}, $hi->{agg_min}, $hi->{agg_max}, $speedup;

if ($opt{csv}) {
    my $new = !-s $opt{csv};
    open(my $fh, '>>', $opt{csv}) or die "open $opt{csv}: $!";
    print $fh "label,conns,reps,spread_cv,straggler,ttfb_cv,agg_mbs,agg_min,agg_max,speedup,span\n" if $new;
    printf $fh "%s,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d\n",
        $opt{label}, $N, $hi->{reps}, $hi->{spread_cv}, $hi->{straggler},
        $hi->{ttfb_cv}, $hi->{agg_mbs}, $hi->{agg_min}, $hi->{agg_max},
        $speedup, $opt{span};
    close $fh;
    print "appended to $opt{csv}\n";
}
