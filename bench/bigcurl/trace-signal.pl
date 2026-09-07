#!/usr/bin/env perl
#
# trace-signal.pl - extract the candidate regime signals S1-S5 from bigcurl's
# `-l` JSON trace. Reads only what bigcurl already emits; adds no
# instrumentation to cli/bigcurl. See SIGNALS.md for what each signal is and
# why it was a candidate.
#
#   S1 retry_per_mb   retry events per MB transferred
#   S2 stall_frac     fraction of retries whose reason mentions a stall
#   S3 speed_cv       stddev/mean of progress.speed across the run
#   S4 conns_*        mean/max/final progress.conns, and how often it fell
#   S5 tail_frac      (t_done - t_first_progress_at_90pct) / t_done
#
# Runs bigcurl --reps times, deletes the output between runs (a run whose
# output already exists is skipped and posts a nonsense time), and verifies
# sha256 against a hash the caller computed fresh on the host.
#
# Usage:
#   trace-signal.pl --bigcurl PATH --url URL --sha SHA256 --out FILE
#                   --reps N --label NAME [--csv FILE] [--keep-traces DIR]
#                   [-- extra bigcurl args...]
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies

use strict;
use warnings;

my %opt = (reps => 5, extra => [], label => 'run');
my @args = @ARGV;
while (@args) {
    my $a = shift @args;
    if    ($a eq '--bigcurl')     { $opt{bigcurl} = shift @args }
    elsif ($a eq '--url')         { $opt{url}     = shift @args }
    elsif ($a eq '--sha')         { $opt{sha}     = shift @args }
    elsif ($a eq '--out')         { $opt{out}     = shift @args }
    elsif ($a eq '--reps')        { $opt{reps}    = shift @args }
    elsif ($a eq '--label')       { $opt{label}   = shift @args }
    elsif ($a eq '--csv')         { $opt{csv}     = shift @args }
    elsif ($a eq '--keep-traces') { $opt{keep}    = shift @args }
    elsif ($a eq '--')            { push @{$opt{extra}}, @args; @args = () }
    else { die "unknown arg: $a\n" }
}
for (qw(bigcurl url sha out)) { die "--$_ required\n" unless $opt{$_} }

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

sub sha256 {
    my ($f) = @_;
    my $prog = -x '/usr/bin/sha256sum' ? 'sha256sum'
             : (`which sha256sum 2>/dev/null` ? 'sha256sum' : 'shasum');
    my @cmd = $prog eq 'shasum' ? ('shasum', '-a', '256', $f) : ('sha256sum', $f);
    open(my $fh, '-|', @cmd) or return '';
    my $l = <$fh>; close $fh;
    return '' unless defined $l;
    return ($l =~ /^(\S+)/)[0] // '';
}

# Deliberately hand-rolled rather than JSON::PP: the trace is one flat object
# per line with no nesting and no escaped quotes in the fields we read, and a
# stripped perl on the droplet may not carry JSON::PP.
sub jfield {
    my ($line, $key) = @_;
    if ($line =~ /"\Q$key\E":"((?:[^"\\]|\\.)*)"/) { my $v = $1; $v =~ s/\\(.)/$1/g; return $v }
    if ($line =~ /"\Q$key\E":(-?[\d.]+)/)          { return $1 }
    return undef;
}

my @rows;
my @failed;
for my $rep (1 .. $opt{reps}) {
    unlink $opt{out}, "$opt{out}.part", "$opt{out}.part.state";
    my @cmd = ($opt{bigcurl}, '-l', @{$opt{extra}}, '-o', $opt{out}, $opt{url});
    my $pid = open(my $fh, '-|');
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>', '/dev/null');
        exec { $cmd[0] } @cmd;
        exit 127;
    }

    my (@speeds, @conns, @retry_reasons);
    my ($t90, $tdone, $rc, $bytes, $secs, $nprog) = (undef, undef, undef, 0, 0, 0);
    my $trace = '';
    while (my $line = <$fh>) {
        $trace .= $line if $opt{keep};
        my $ev = jfield($line, 'event') or next;
        if ($ev eq 'progress') {
            $nprog++;
            my $sp = jfield($line, 'speed');
            my $cn = jfield($line, 'conns');
            my $pc = jfield($line, 'pct');
            # Only steady state counts. progress.speed is an EMA that starts at
            # zero, so including the ramp manufactures a large CV on every link
            # alike and swamps the between-regime difference we are looking for
            # - it read 0.87 on an idle loopback origin.
            push @speeds, $sp if defined($sp) && defined($pc) && $pc >= 10;
            push @conns,  $cn if defined($cn) && defined($pc) && $pc >= 10;
            $t90 = jfield($line, 'ts') if !defined($t90) && defined($pc) && $pc >= 90;
        } elsif ($ev eq 'retry') {
            push @retry_reasons, (jfield($line, 'reason') // '?');
        } elsif ($ev eq 'done') {
            $tdone = jfield($line, 'ts');
            $bytes = jfield($line, 'bytes') // 0;
            $secs  = jfield($line, 'seconds') // 0;
        } elsif ($ev eq 'summary') {
            $rc = jfield($line, 'exit');
        }
    }
    close $fh;

    my $shaok = sha256($opt{out}) eq $opt{sha};
    unless (defined($tdone) && ($rc // 1) == 0 && $shaok && $bytes > 0) {
        push @failed, $rep;
        printf "  rep %d: FAILED (rc=%s tdone=%s sha_ok=%d bytes=%s)\n",
            $rep, $rc // 'undef', $tdone // 'undef', $shaok ? 1 : 0, $bytes;
        next;
    }
    # A trace with no progress samples yields a speed_cv and a conns trajectory
    # of nothing at all; that is a broken measurement, not a quiet link.
    if ($nprog < 3 || scalar(@speeds) < 3) {
        push @failed, $rep;
        printf "  rep %d: FAILED (only %d progress samples, %d of them steady-state - too short to measure)\n",
            $rep, $nprog, scalar(@speeds);
        next;
    }

    if ($opt{keep}) {
        mkdir $opt{keep} unless -d $opt{keep};
        if (open(my $tf, '>', "$opt{keep}/$opt{label}.rep$rep.jsonl")) {
            print {$tf} $trace;
            close $tf;
        }
    }

    my $mb      = $bytes / 1e6;
    my $stalls  = scalar grep { /stall/i } @retry_reasons;
    my $drops   = 0;
    $drops++ for grep { $conns[$_] < $conns[$_ - 1] } (1 .. $#conns);

    my $row = {
        rep         => $rep,
        secs        => $secs,
        mbs         => $secs > 0 ? $mb / $secs : 0,
        retries     => scalar @retry_reasons,
        retry_per_mb=> $mb > 0 ? scalar(@retry_reasons) / $mb : 0,
        stall_frac  => scalar(@retry_reasons) ? $stalls / scalar(@retry_reasons) : 0,
        speed_cv    => mean(@speeds) > 0 ? sd(@speeds) / mean(@speeds) : 0,
        conns_mean  => mean(@conns),
        conns_max   => (sort { $b <=> $a } @conns)[0] // 0,
        conns_final => $conns[-1] // 0,
        conns_drops => $drops,
        tail_frac   => (defined($t90) && $tdone > 0) ? ($tdone - $t90) / $tdone : 0,
        nprog       => $nprog,
    };
    push @rows, $row;
    printf "  rep %d: %.2f MB/s retries=%d (%.3f/MB, stall %.0f%%) speed_cv=%.3f conns mean/max/fin=%.1f/%d/%d drops=%d tail=%.3f\n",
        $rep, $row->{mbs}, $row->{retries}, $row->{retry_per_mb},
        100 * $row->{stall_frac}, $row->{speed_cv}, $row->{conns_mean},
        $row->{conns_max}, $row->{conns_final}, $row->{conns_drops}, $row->{tail_frac};
}

# Assert a non-trivial number of rows was actually compared. A silent zero here
# is exactly the vacuous gate this run has already been burned by.
die "\n$opt{label}: ALL $opt{reps} REPS FAILED - no rows, refusing to report\n" unless @rows;
if (scalar(@rows) < 3) {
    warn "\n$opt{label}: WARNING only " . scalar(@rows) . "/$opt{reps} reps usable; spreads are not trustworthy\n";
}

my %m;
for my $k (qw(mbs retries retry_per_mb stall_frac speed_cv conns_mean conns_max conns_final conns_drops tail_frac)) {
    $m{$k}      = median(map { $_->{$k} } @rows);
    $m{"${k}_lo"} = (sort { $a <=> $b } map { $_->{$k} } @rows)[0];
    $m{"${k}_hi"} = (sort { $b <=> $a } map { $_->{$k} } @rows)[0];
}

printf "\nRESULT %s: n=%d/%d verified reps\n", $opt{label}, scalar(@rows), $opt{reps};
printf "  throughput   %.2f MB/s   [%.2f .. %.2f]\n", $m{mbs}, $m{mbs_lo}, $m{mbs_hi};
printf "  S1 retry/MB  %.4f        [%.4f .. %.4f]  (%d retries median)\n",
    $m{retry_per_mb}, $m{retry_per_mb_lo}, $m{retry_per_mb_hi}, $m{retries};
printf "  S2 stall_frac %.3f       [%.3f .. %.3f]\n", $m{stall_frac}, $m{stall_frac_lo}, $m{stall_frac_hi};
printf "  S3 speed_cv  %.3f        [%.3f .. %.3f]\n", $m{speed_cv}, $m{speed_cv_lo}, $m{speed_cv_hi};
printf "  S4 conns     mean %.1f [%.1f .. %.1f]  max %.0f  final %.0f  drops %.0f\n",
    $m{conns_mean}, $m{conns_mean_lo}, $m{conns_mean_hi}, $m{conns_max}, $m{conns_final}, $m{conns_drops};
printf "  S5 tail_frac %.3f        [%.3f .. %.3f]\n", $m{tail_frac}, $m{tail_frac_lo}, $m{tail_frac_hi};

if ($opt{csv}) {
    my $new = !-s $opt{csv};
    open(my $fh, '>>', $opt{csv}) or die "open $opt{csv}: $!";
    print $fh "label,reps,mbs,mbs_lo,mbs_hi,retry_per_mb,retry_per_mb_lo,retry_per_mb_hi,"
            . "retries,stall_frac,speed_cv,speed_cv_lo,speed_cv_hi,conns_mean,conns_max,"
            . "conns_final,conns_drops,tail_frac,tail_frac_lo,tail_frac_hi\n" if $new;
    printf $fh "%s,%d,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.1f,%.4f,%.4f,%.4f,%.4f,%.2f,%.0f,%.0f,%.1f,%.4f,%.4f,%.4f\n",
        $opt{label}, scalar(@rows), $m{mbs}, $m{mbs_lo}, $m{mbs_hi},
        $m{retry_per_mb}, $m{retry_per_mb_lo}, $m{retry_per_mb_hi}, $m{retries},
        $m{stall_frac}, $m{speed_cv}, $m{speed_cv_lo}, $m{speed_cv_hi},
        $m{conns_mean}, $m{conns_max}, $m{conns_final}, $m{conns_drops},
        $m{tail_frac}, $m{tail_frac_lo}, $m{tail_frac_hi};
    close $fh;
    print "appended to $opt{csv}\n";
}
