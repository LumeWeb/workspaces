#!/bin/sh
# Pinner WordPress cron worker.
#
# WP cron is disabled for web traffic (DISABLE_WP_CRON) and web-driven updates
# are off entirely (DISALLOW_FILE_MODS, AUTOMATIC_UPDATER_DISABLED); this worker
# is the only thing that ticks the scheduler. It runs as www-data (executed by
# pinner-supervise.sh after the base entrypoint's privilege drop) and drives
# WP's OWN scheduler: every tick WP-CLI runs only the events WP considers due,
# so cron semantics stay WordPress-native — there is no DIY cron daemon, no
# crontab, and no schedule duplicated outside WP. It ALSO fires Action
# Scheduler's own queue hook on every tick, so due Action Scheduler actions
# run on this same short cadence instead of waiting for Action Scheduler's
# 1-minute WP-Cron queue event. Neither is a DIY scheduler: both are the
# site's own queue, driven directly.
#
# Lifecycle: this is a supervised child, so a crash takes the container down
# with it (fail-fast, like PHP-FPM/Caddy). Transient WP failures (DB coming up,
# install deferred to a later boot) must therefore never be fatal: they are
# logged as warnings and retried on the next tick. TERM/INT/QUIT exit cleanly
# for a graceful `docker stop`.

set -u

DOCROOT=/var/www/html
INTERVAL="${WP_CRON_INTERVAL:-30}"
WP=/usr/local/bin/wp

shutdown() {
    trap - TERM INT QUIT
    exit 0
}
trap shutdown TERM INT QUIT

# Wait until the site is installed before ticking the scheduler; anything the
# scheduler would run before that has nothing to run against anyway. Retries
# are quiet and unbounded by design: the container as a whole is healthy while
# install is deferred (see wp-init.sh), and this worker must not be the thing
# that flips it unhealthy.
while ! "$WP" --path="$DOCROOT" core is-installed >/dev/null 2>&1; do
    sleep "$INTERVAL"
done || exit 1

while :; do
    # --due-now runs only events whose next-run time is due; WP's scheduler
    # stays authoritative. Output is discarded (the WP admin UI and
    # `wp cron event list` remain the way to observe results); a failing run is
    # warned on stderr and retried next tick.
    if ! "$WP" --path="$DOCROOT" cron event run --due-now >/dev/null 2>&1; then
        echo "WARN: [wp-cron] 'wp cron event run --due-now' failed; will retry next tick" >&2
    fi
    # Action Scheduler's own queue event only fires on a 1-minute WP-Cron
    # schedule, so due actions would otherwise wait up to a minute. Fire the
    # same 'action_scheduler_run_queue' hook that event triggers — the same
    # way Action Scheduler's own async runner does it, with an explicit
    # context — so due actions run on THIS worker's cadence. The
    # class_exists guard makes this a no-op on sites without Action Scheduler
    # (Cast vendors it); a failing run is warned on stderr and retried next
    # tick, never fatal to supervision.
    if ! "$WP" --path="$DOCROOT" eval '
        if ( class_exists( "ActionScheduler_QueueRunner" ) ) {
            do_action( "action_scheduler_run_queue", "Pinner WP Cron" );
        }
    ' >/dev/null 2>&1; then
        echo "WARN: [wp-cron] Action Scheduler queue run failed; will retry next tick" >&2
    fi
    sleep "$INTERVAL"
done
