package App::berkala;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use POSIX ":sys_wait_h";

our $Config;
our $Tasks;

sub _parse_crontab_time {
    my $time = shift;

    my @elems = split /\s+/, $time;
    return {error=>'Not 5 elements'} if @elems != 5;
    my $res = {};
    for my $i (0..$#elems) {
        my $elem = $elems[$i];
        my ($k, $low, $high);
        if ($i==0) {
            $k = 'min'; $low = 0; $high = 59;
        } elsif ($i==1) {
            $k = 'hour'; $low = 0; $high = 23;
        } elsif ($i==2) {
            $k = 'day'; $low = 1; $high = 31;
        } elsif ($i==3) {
            $k = 'mon'; $low = 1; $high = 12;
        } elsif ($i==4) {
            $k = 'dow'; $low = 0; $high = 6;
        }
        my @list = split /,/, $elem;
        for my $j (0..$#list) {
            my $lelem = $list[$j];
            if ($lelem eq '*') {
                next;
            } elsif ($lelem =~ /\A\d+\z/) {
                if ($lelem < $low || $lelem > $high) {
                    return {error=>"$k#$j: number must be between $low and $high"};
                }
            } elsif ($lelem =~ m!\A\*/([1-9][0-9]*)\z!) {
                $list[$j] = -$1;
            } else {
                return {error=>"$k#$j: invalid pattern '$lelem'"};
            }
        }
        $res->{$k} = \@list;
    }
    $res;
}

sub read_config {
    require Config::IOD::Reader;

    my $reader = Config::IOD::Reader->new(
    );

    my $new_config = {};

    for my $path (
        "$ENV{HOME}/berkala.ini",
        "$ENV{HOME}/.config/berkala.ini",
    ) {
        next unless -f $path;
        my $hoh;
        log_debug "Reading configuration file '$path' ...";
        eval { $hoh = $reader->read_file($path) };
        if ($@) {
            log_error "Cannot parse configuration file '$path': $@";
            next;
        }
        for my $section (keys %$hoh) {
            my $hash = $hoh->{$section};
            for my $k (keys %$hash) {
                $new_config->{$section}{$k} = $hash->{$k};
            }
        }
    }

    my $new_tasks = {};
    for my $section (keys %$new_config) {
        my $hash = $new_config->{$section};

        if ($section =~ m!\Ajob/(.*)!) {
            my $name = $1;
            if (!length $name) {
                log_error "config: section [$section]: name must not be empty, section ignored";
                delete $new_config->{$section};
                next;
            } elsif ($name !~ /\A\w+(?:-\w+)*\z/) {
                log_error "config: section [$section]: invalid task name (must be alphanumeric words separated with dash), section ignored";
                delete $new_config->{$section};
                next;
            }

            if ($new_tasks->{$name}) {
                log_error "config: section [$section]: duplicate task name '$name', section ignored";
                delete $new_config->{$section};
                next;
            }
            my $task = {%$hash};

            if (!defined($task->{command})) {
                log_error "config: task '$name': no command specified, task ignored";
                next;
            }
            my $res = _parse_crontab_time($hash->{every});
            if ($res->{error}) {
                log_error "config: task '$name': invalid 'every' specification: $res->{error}, task ignored";
                next;
            }
            $task->{_every_parsed} = $res;
            $new_tasks->{$name} = $task;
            log_debug "Registered task '$name'";

        } else {
            log_error "config: invalid section '$section', ignored";
            delete $new_config->{$section};
            next;
        }
    }

    $Config = $new_config;
    $Tasks  = $new_tasks;
}

sub list_tasks {
    my %args = @_;

    my @res;
    my %seen;
    for my $name (sort keys %$Tasks) {
        my $task = $Tasks->{$name};
        if ($args{detail}) {
            say "$name\t$task->{every}";
        } else {
            say $name;
        }
    }
    0;
}

sub _run_task {
    require Proc::Govern;

    my $task = shift;

    my $cmd = ref $task->{command} eq 'ARRAY' ? $task->{command} :
        ["bash", "-c", $task->{command}];
    my %govargs = (
        command => $cmd,
    );
    my $pid = fork();
    if (!defined $pid) {
        log_error "Can't fork: $!";
    } elsif ($pid) {
        log_trace "Running command %s (pid %d) ...", $cmd, $pid;
        1 while waitpid(-1, WNOHANG) > 0;
    } else {
        if ($task->{env}) {
            $ENV{$_} = $task->{env}{$_} for keys %{ $task->{env} };
        }
        exit Proc::Govern::govern_process(%govargs);
    }
}

sub _run_tasks {
    my @lt = @_;

    log_debug "Running tasks ...";
  TASK:
    for my $name (sort keys %$Tasks) {
        my $task = $Tasks->{$name};
        my $match = 1;
        my $every_parsed = $task->{_every_parsed};

      MIN: {
            my $list = $every_parsed->{min};
            my $opn = $lt[1];
            for my $el (@$list) {
                if ($el eq '*') {
                    last MIN;
                } elsif ($el >= 0) {
                    last MIN if $el == $opn;
                } else {
                    last MIN if $opn % $el == 0;
                }
            }
            $match = 0; goto RUN;
        }
      HOUR: {
            my $list = $every_parsed->{hour};
            my $opn = $lt[2];
            for my $el (@$list) {
                if ($el eq '*') {
                    last HOUR;
                } elsif ($el >= 0) {
                    last HOUR if $el == $opn;
                } else {
                    last HOUR if $opn % $el == 0;
                }
            }
            $match = 0; goto RUN;
        }
      DAY: {
            my $list = $every_parsed->{day};
            my $opn = $lt[3];
            for my $el (@$list) {
                if ($el eq '*') {
                    last DAY;
                } elsif ($el >= 0) {
                    last DAY if $el == $opn;
                } else {
                    last DAY if $opn % $el == 0;
                }
            }
            $match = 0; goto RUN;
        }
      MON: {
            my $list = $every_parsed->{mon};
            my $opn = $lt[4]+1;
            for my $el (@$list) {
                if ($el eq '*') {
                    last MON;
                } elsif ($el >= 0) {
                    last MON if $el == $opn;
                } else {
                    last MON if $opn % $el == 0;
                }
            }
            $match = 0; goto RUN;
        }
      DOW: {
            my $list = $every_parsed->{dow};
            my $opn = $lt[6];
            for my $el (@$list) {
                if ($el eq '*') {
                    last DOW;
                } elsif ($el >= 0) {
                    last DOW if $el == $opn;
                } else {
                    last DOW if $opn % $el == 0;
                }
            }
            $match = 0; goto RUN;
        }

      RUN:
        unless ($match) {
            log_trace "Task '$name' ($task->{every}) should not be run right now";
            next TASK;
        }
        log_info "Running task '$name' ($task->{every}) ...";
        _run_task($task);
    }
}

sub start_daemon {
    die "Not yet implemented";
}

sub start_interactive {
    my %args = @_;

    my $last_minute;
    while (1) {
        my $time = time();
        my @lt = localtime $time;
        if (defined $last_minute && $last_minute == $lt[1]) {
            goto SLEEP;
        }
        log_trace "Right now is: sec=%02d min=%02d hour=%02d day=%02d mon=%02d dow=%d",
            $lt[0], $lt[1], $lt[2], $lt[3], $lt[4]+1, $lt[6];
        _run_tasks(@lt);
        $last_minute = $lt[1];

      SLEEP:
        sleep 1;
    }
}

sub stop_daemon {
    die "Not yet implemented";
}

1;
#ABSTRACT: Execute scheduled commands

=head1 SYNOPSIS

See the included L<berkala> script.

=cut
