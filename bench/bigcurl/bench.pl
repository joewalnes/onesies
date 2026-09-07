#!/usr/bin/perl
# bench.pl - time a set of downloaders against one URL, emit CSV.
#
#   bench.pl --base http://host:8080 --path big-1g.bin --label "desktop->do" \
#            --reps 3 --tools curl,aria2-16,bigcurl-auto --out results.csv
#
# Records wall clock, child CPU, and whether the bytes came back intact.
use strict;
use warnings;
use FindBin;
use Time::HiRes qw(time);
use File::Path  qw(rmtree);

# AIDEV-NOTE: byteproxy defaults to a sibling of this script so the common
# case (both scp'd to the same /root/) needs no extra flag; --byteproxy
# still overrides it, same pattern as --bigcurl.
my %o = (reps => 3, out => 'results.csv', tools => 'curl,aria2-16,bigcurl-auto',
         label => 'unlabelled', workdir => '/tmp/benchwork', warmup => 1,
         timeout => 0, prefix => '', byteproxy => "$FindBin::Bin/byteproxy.sh");
while (@ARGV) {
    my $a = shift @ARGV;
    $a =~ s/^--//;
    $o{$a} = shift @ARGV;
}
die "need --base and --path\n" unless $o{base} && $o{path};

my $url = "$o{base}/$o{path}";
my $wd  = $o{workdir};
rmtree($wd); mkdir $wd or die "mkdir $wd: $!";

sub sha256 {
    my ($f) = @_;
    my $cmd = -x '/usr/bin/shasum' ? "shasum -a 256 '$f'" : "sha256sum '$f'";
    my $out = `$cmd 2>/dev/null`;
    return ($out =~ /^(\w{64})/) ? $1 : '';
}

# Reference digest: one plain curl pull, retried, before anything is measured.
my $ref = $o{sha} || '';
unless ($ref) {
    for (1 .. 3) {
        system("curl -sS --retry 3 -o '$wd/ref' '$url'") == 0 or next;
        $ref = sha256("$wd/ref");
        last if $ref;
    }
    die "could not fetch a reference copy of $url\n" unless $ref;
    unlink "$wd/ref";
}
my $size = 0;
{
    my $h = `curl -sSI -L '$url' 2>/dev/null`;
    $size = $1 if $h =~ /content-length:\s*(\d+)/i;
}

# Run a command, killing its whole process group if it outlives the cap.
# A timed-out run is recorded as a failure, which is itself a result.
sub run_capped {
    my ($cmd, $cap) = @_;
    return system($cmd) unless $cap;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        setpgrp(0, 0);
        exec('/bin/sh', '-c', $cmd);
        exit 127;
    }
    my $rc = -1;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $cap;
        waitpid($pid, 0);
        $rc = $?;
        alarm 0;
    };
    if ($@) {
        kill('KILL', -$pid);
        waitpid($pid, 0);
        return -1;
    }
    return $rc;
}

sub cmd_for {
    my ($tool, $out) = @_;
    return "curl -sS --fail -o '$out' '$url'"                       if $tool eq 'curl';
    return "wget -q -O '$out' '$url'"                               if $tool eq 'wget';
    if ($tool =~ /^aria2-(\d+)$/) {
        return "aria2c -q -x $1 -s $1 -k 1M --file-allocation=none "
             . "--console-log-level=error --summary-interval=0 "
             . "-d '$wd' -o '" . ($out =~ m{([^/]+)$})[0] . "' '$url'";
    }
    return "axel -q -n $1 -o '$out' '$url'"                         if $tool =~ /^axel-(\d+)$/;
    return "$o{bigcurl} -s -o '$out' '$url'"                        if $tool eq 'bigcurl-auto';
    return "$o{bigcurl} -s -n $1 -o '$out' '$url'"                  if $tool =~ /^bigcurl-(\d+)$/;
    # AIDEV-NOTE: ASK 2 instrument. curlo-N / curldd-N drive byteproxy.sh at
    # a PINNED connection count N, matching bigcurl-N in the tools list, so
    # the comparison isolates perl's read+write byte-path cost from the
    # connection-count effects that made bigcurl-auto vs curl a misleading
    # comparison for ASK 1. See byteproxy.sh for what each mode proxies and
    # its portability limits (curldd requires bs-aligned piece boundaries).
    return "$o{byteproxy} curlo $1 '$url' '$out'"                   if $tool =~ /^curlo-(\d+)$/;
    return "$o{byteproxy} curldd $1 '$url' '$out'"                  if $tool =~ /^curldd-(\d+)$/;
    die "unknown tool $tool\n";
}

my $new = !-e $o{out};
open(my $csv, '>>', $o{out}) or die "$o{out}: $!";
print $csv "label,tool,rep,seconds,mbps,cpu_user,cpu_sys,ok,timeout,bytes\n" if $new;
$| = 1;

printf("%-28s %-14s %9s %10s %6s\n", 'scenario', 'tool', 'secs', 'MB/s', 'ok');
# AIDEV-NOTE: rep-major, not tool-major. On a link whose capacity drifts
# (Starlink, say) running every repetition of one tool back to back charges
# that tool for whatever the weather was doing; interleaving spreads the drift
# across all of them.
my @tools = split /,/, $o{tools};
for my $rep (1 .. $o{reps} + $o{warmup}) {
    for my $tool (@tools) {
        my $out = "$wd/dl.bin";
        unlink $out;
        unlink glob("$wd/*.aria2");
        my $cmd = cmd_for($tool, $out);
        my @t0  = times();
        my $t0  = time();
        my $rc  = run_capped("$o{prefix}$cmd >/dev/null 2>&1", $o{timeout});
        my $el  = time() - $t0;
        my @t1  = times();
        my $to  = ($rc == -1) ? 1 : 0;
        my $ok  = ($rc == 0 && sha256($out) eq $ref) ? 1 : 0;
        my $by  = (-s $out) || (-s "$out.part") || 0;
        unlink $out, "$out.part", "$out.part.state";
        next if $rep <= $o{warmup};
        my $mbps = $el > 0 ? ($by / 1048576) / $el : 0;
        printf("%-28s %-14s %9.2f %10.2f %6s\n", $o{label}, $tool, $el, $mbps,
               $ok ? 'yes' : ($to ? 'T/O' : 'NO'));
        printf $csv "%s,%s,%d,%.3f,%.3f,%.2f,%.2f,%d,%d,%d\n", $o{label}, $tool,
               $rep - $o{warmup}, $el, $mbps, $t1[2] - $t0[2], $t1[3] - $t0[3],
               $ok, $to, $by;
    }
}
close $csv;
rmtree($wd);
