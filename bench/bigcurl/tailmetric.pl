#!/usr/bin/env perl
#
# tailmetric.pl - measure "time from 90% to done" from a bigcurl -l trace,
# for ASK 3 (hedged tail requests). Runs bigcurl N times, deletes the output
# between runs, verifies sha256 against a hash the caller must have computed
# fresh on the host, and reports every rep's tail time plus a median/spread -
# not just a median, since Starlink is the noisiest link this is measured on.
#
# Usage:
#   tailmetric.pl --bigcurl PATH --url URL --sha SHA256 --out FILE
#                 --reps N [--hedge N] [-- extra bigcurl args...]

use strict;
use warnings;
use JSON::PP qw(decode_json);

my %opt = (reps => 5, hedge => undef, extra => []);
my @args = @ARGV;
while (@args) {
    my $a = shift @args;
    if    ($a eq '--bigcurl') { $opt{bigcurl} = shift @args }
    elsif ($a eq '--url')     { $opt{url}     = shift @args }
    elsif ($a eq '--sha')     { $opt{sha}     = shift @args }
    elsif ($a eq '--out')     { $opt{out}     = shift @args }
    elsif ($a eq '--reps')    { $opt{reps}    = shift @args }
    elsif ($a eq '--hedge')   { $opt{hedge}   = shift @args }
    elsif ($a eq '--')        { push @{$opt{extra}}, @args; @args = () }
    else { die "unknown arg: $a\n" }
}
for (qw(bigcurl url sha out)) { die "--$_ required\n" unless $opt{$_} }

sub sha256 {
    my ($f) = @_;
    open(my $fh, '-|', 'sha256sum', $f) or return '';
    my $l = <$fh>; close $fh;
    return '' unless defined $l;
    ($l =~ /^(\S+)/)[0] // '';
}

my @tails;
my @fails;
for my $rep (1 .. $opt{reps}) {
    unlink $opt{out}, "$opt{out}.part", "$opt{out}.part.state";
    my @cmd = ($opt{bigcurl}, '-l');
    push @cmd, '--hedge', $opt{hedge} if defined $opt{hedge};
    push @cmd, @{$opt{extra}};
    push @cmd, '-o', $opt{out}, $opt{url};
    my $pid = open(my $fh, '-|');
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>', '/dev/null');
        exec { $cmd[0] } @cmd;
        exit 127;
    }
    my ($t90, $tdone, $rc);
    while (my $line = <$fh>) {
        my $e = eval { decode_json($line) };
        next unless $e;
        if ($e->{event} eq 'progress' && !defined($t90) && $e->{pct} >= 90) {
            $t90 = $e->{ts};
        }
        if ($e->{event} eq 'done') {
            $tdone = $e->{ts};
        }
        if ($e->{event} eq 'summary') {
            $rc = $e->{exit};
        }
    }
    close $fh;
    my $ok = defined($t90) && defined($tdone) && ($rc // 1) == 0;
    my $shaok = $ok && sha256($opt{out}) eq $opt{sha};
    if ($ok && $shaok) {
        my $tail = $tdone - $t90;
        push @tails, $tail;
        printf "rep %d: t90=%.2f tdone=%.2f tail=%.2f verified=1\n", $rep, $t90, $tdone, $tail;
    } else {
        push @fails, $rep;
        printf "rep %d: FAILED (rc=%s t90=%s tdone=%s shaok=%s)\n",
            $rep, $rc // 'undef', $t90 // 'undef', $tdone // 'undef', $shaok ? 1 : 0;
    }
}

if (@tails) {
    my @s = sort { $a <=> $b } @tails;
    my $n = scalar @s;
    my $median = $n % 2 ? $s[$n/2] : ($s[$n/2-1]+$s[$n/2])/2;
    printf "\nn=%d verified, %d failed. tail seconds: min=%.2f median=%.2f max=%.2f\n",
        $n, scalar(@fails), $s[0], $median, $s[-1];
    print "all: ", join(', ', map { sprintf('%.2f', $_) } @s), "\n";
} else {
    print "\nALL REPS FAILED - no data\n";
    exit 1;
}
