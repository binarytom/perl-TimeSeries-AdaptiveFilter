package TimeSeries::AdaptiveFilter;

use strict;
use warnings;

use List::Util qw(sum max);

use parent qw/Exporter/;

our @EXPORT_OK = qw/filter/;

our $VERSION = '0.01';

# private lexical function, which calculates MAD (mean absolute deviation)
my $_mad = sub {
    my ($mad, $ad, $trust, $density, $ds) = @_;
    my $mu = $trust * (1 - exp(-$density * $ds));
    return (1 - $mu) * $mad + $mu * $ad;
};

my $sqrt2pi = 1 / sqrt(2 * atan2(1, 1));

sub filter {
    my $params = shift;

    ##############################
    ## filter tuning parameters ##
    ##############################

    # minimum amount of values in lookback to take an decision.
    # Otherwise, input values will be accepted
    my $floor = $params->{floor} // 6;
    # maximum share of rejected input values. Upon hit, input values will be accepted
    my $cap = $params->{cap} // 0.2;
    # maximum amount ot input values in lookback
    my $lookback_capacity = $params->{lookback_capacity} // 20;
    # the retention period for lookback, i.e. max age for input values
    my $lookback_period  = $params->{lookback_period}  // 4;
    my $decay_speeds     = $params->{decay_speeds}     // [0.03, 0.01, 0.003];
    my $build_up_count   = $params->{build_up_count}   // 5;
    my $reject_criterium = $params->{reject_criterium} // 4;

    ########################
    ## enclosed variables ##
    ########################

    my $lookback          = [];
    my $lookback_rejected = 0;
    my $minute            = [];
    my $trust_w;
    my $ad;
    my $ads = [];    # used on build stage only
    my $mad;
    my $mads;
    my $wsum = 0;
    my $csum = 0;
    my $vol;
    my $_accepted;

    # flag initicates, that we still need to accumulate enough time series
    # before doing actual filtering.
    my $build = 1;

    # resulting adaptive filter function
    my $fn = sub {
        my ($epoch, $spot) = @_;

        # operating on nature log
        $spot = log $spot;

        # prevent loopback window overgrow
        while (@$lookback > $lookback_capacity or @$lookback > $floor and $lookback->[0][0] < $epoch - $lookback_period) {
            my $leaving = shift @$lookback;
            --$lookback_rejected unless $leaving->[3];
        }
        my $accepted;

        if ($build) {
            # always accept the incoming value
            ($trust_w, $accepted) = (1, 1);

            # gather absolute differences
            unless (@$lookback < $build_up_count) {
                $ad = abs($spot - $lookback->[-$build_up_count][1]) / sqrt($build_up_count);
                push @$ads, $ad;
            }

            # build condition: the current tick is 60s newer
            # and we have enough absolute differences
            if (    @$minute
                and $minute->[0] < $epoch - 60
                and @$ads >= $build_up_count)
            {
                $build = 0;
                my @ads = sort { $a <=> $b } @$ads;
                my $cut = int(@ads / $build_up_count);
                @ads  = @ads[$cut .. ($build_up_count - 1) * $cut];
                $mad  = sum(@ads) / @ads;
                $mads = [($mad) x scalar(@$decay_speeds)];
            }
        } else {
            # prevent $minute array overgrow
            while (@$minute and $minute->[0] < $epoch - 60) {
                shift @$minute;
            }
            my $density = 60 / (1 + @$minute);    # the number "1", beacuse we account the current value too
            my $ha      = $wsum / $csum;
            my $vol     = $mad / $sqrt2pi;
            my $diff    = abs($spot - $ha);

            # ther there is zero-difference, we accept current piece of data;
            # otherwise, if it is zero-volatility (flat), we reject it.
            my $reject =
                $diff
                ? ($vol ? ($diff / $vol) : $reject_criterium + 1)
                : 0;

            $accepted = !($reject > $reject_criterium);
            $trust_w = 1 / (1 + ($reject / $reject_criterium)**8);

            if (not $accepted and $lookback_rejected > $cap * @$lookback) {
                ($accepted, $trust_w) = (1, 1);
            }
            $ad = abs($spot - $_accepted->[-$build_up_count][1]) / sqrt($build_up_count);
            if ($ad) {
                for my $idx (0 .. @$decay_speeds - 1) {
                    $mads->[$idx] = $_mad->($mads->[$idx], $ad, $trust_w, $density, $decay_speeds->[$idx]);
                }
            }
            $mad = max(@$mads);
        }
        push @$minute, $epoch;
        push @$lookback, [$epoch, $spot, $trust_w, $accepted];
        if ($accepted) {
            push @$_accepted, [$epoch, $spot];
            shift @$_accepted while @$_accepted > $build_up_count;
        } else {
            ++$lookback_rejected;
        }
        if ($trust_w) {
            $wsum = 0.5 * $wsum + $spot * $trust_w;
            $csum = 0.5 * $csum + $trust_w;
        }
        return $accepted;
    };
    return $fn;
}

1;
