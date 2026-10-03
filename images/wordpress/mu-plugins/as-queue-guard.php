<?php

/**
 * Plugin Name: Pinner Action Scheduler Queue Guard
 * Description: Serializes Action Scheduler queue runs so the supervised WP-cron
 *              worker's every-tick drive cannot overlap a batch with AS's own
 *              1-minute WP-Cron event or its async-request runner. Registered
 *              before the AS queue runner on every action_scheduler_run_queue;
 *              a run that cannot acquire the queue lock is dropped instead of
 *              staking a second, overlapping claim.
 * Version:     0.1.0
 * Author:      LumeWeb
 * License:     GPL-3.0-or-later
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

/**
 * Lock type for the queue-run guard. Deliberately distinct from AS's own
 * 'async-request-runner' lock (used to throttle async dispatch to once per
 * 60s) so the two never contend with each other.
 */
const PINNER_AS_QUEUE_LOCK = 'pinner-queue-run';

/**
 * Align the guard lock's duration with AS's own per-batch time limit (30s
 * default), so a single (normal) batch cannot be overlapped by a concurrent
 * queue run.
 *
 * Why this is the correct filter (verified against the vendored Action
 * Scheduler 4.2.0 in the Cast plugin):
 *   - Kody suggested 'action_scheduler_lock_timeout'; that filter does NOT
 *     exist in AS 4.2. The real lock-duration filter is
 *     'action_scheduler_lock_duration' (ActionScheduler_Lock::get_duration()).
 *   - That lock only gates the ASYNC dispatch throttle. The queue run itself
 *     is serialized by the CLAIM COUNT (has_maximum_concurrent_batches(),
 *     driven by 'action_scheduler_queue_runner_concurrent_batches' = 1), which
 *     has a start-up TOCTOU window: two runs that both start before either
 *     stakes its claim both proceed. The guard below closes that window with a
 *     compare-and-swap lock; its duration is anchored to the batch time limit
 *     so a batch running within it is fully covered, and a batch that outlives
 *     it is backstopped by the claim-count guard.
 *
 * Scoped to our lock type only, so AS's async-request dispatch throttle keeps
 * its 60s default.
 */
add_filter(
    'action_scheduler_lock_duration',
    static function ($duration, $lock_type) {
        if (PINNER_AS_QUEUE_LOCK !== $lock_type) {
            return $duration;
        }
        $batch_limit = (int) apply_filters('action_scheduler_queue_runner_time_limit', 30);

        return max(30, $batch_limit);
    },
    10,
    2
);

/**
 * Serialize the queue run. Registered at priority 5, so it runs BEFORE AS's
 * queue runner (priority 10) on every action_scheduler_run_queue invocation.
 *
 * The supervised worker, AS's own WP-Cron event, and the async-request runner
 * all converge on this one hook, and every one of them loads mu-plugins — so a
 * global guard here covers all of them. (A per-invocation add_filter in the
 * worker's `wp eval` would only cover that single process, not the native
 * WP-Cron event or the async request runner.)
 *
 * Acquire the compare-and-swap lock; on success keep the runner attached and
 * let it run. If a concurrent run already holds the lock, remove the runner's
 * handler for THIS process so this run is a no-op instead of an overlapping
 * batch.
 */
function pinner_as_queue_run_guard(): void
{
    if (!class_exists('ActionScheduler_QueueRunner') || !class_exists('ActionScheduler')) {
        return;
    }

    if (ActionScheduler::lock()->set(PINNER_AS_QUEUE_LOCK)) {
        return; // we own the lock; the runner proceeds below
    }

    // A concurrent queue run holds the lock: drop the runner so THIS run is a
    // no-op rather than an overlapping batch.
    remove_action('action_scheduler_run_queue', array(ActionScheduler_QueueRunner::instance(), 'run'));
}

add_action('action_scheduler_run_queue', 'pinner_as_queue_run_guard', 5);
