defmodule Tymeslot.Integrations.HealthCheck.MonitorConcurrentTest do
  @moduledoc """
  Composition tests for the health-check lifecycle under concurrent
  or sustained failure scenarios that no single unit test pins down.

  Two invariants are covered:

    * **Concurrent-race exactly-one notification.** Two workers
      simultaneously running the full health-check lifecycle
      (get_state → update_health → put_state → detect_transition →
      handle_transition) on an integration that has already been
      unhealthy for >48h must enqueue exactly one user notification
      email — not zero (both suppressed), not two (silent duplicate).
      The guarantee rests on Oban's `unique:` job constraint; this
      test pins that contract under real concurrent load so a future
      change to the constraint or the lifecycle would surface here.

    * **Transient-failure grace period.** A healthy integration that
      sees a burst of transient errors during (for example) a deploy
      rollout must not flip to `:unhealthy`. `update_health/2`'s
      backoff ramp (5 → 10 → 20 → 40 → 60min) only starts incrementing
      `failures` once the backoff has reached the max. A walk through
      the ramp confirms no `:became_unhealthy` transition fires during
      the grace period.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations
  @moduletag :health_check

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.HealthCheck.ResponseHandler
  alias Tymeslot.Workers.EmailWorker

  describe "concurrent update_health on a sustained-unhealthy integration" do
    test "two workers race the 48h notification — exactly one email job is enqueued" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      # Seed the integration's health state so both workers will see
      # an integration that has been unhealthy for 49h (past the 48h
      # threshold) with no notification previously sent. From this
      # starting point, both workers' `maybe_notify_user` checks must
      # pass and both will try to enqueue a notification email.
      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      unhealthy_since = DateTime.add(DateTime.utc_now(), -49, :hour)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          status: "unhealthy",
          failures: 3,
          consecutive_hard_failures: 3,
          successes: 0,
          backoff_ms: :timer.hours(1),
          last_check_at: DateTime.utc_now(),
          last_error_class: "hard",
          became_unhealthy_at: unhealthy_since,
          notification_sent_at: nil
        )

      parent = self()

      worker = fn ->
        # Each worker runs the full health-check orchestration loop
        # concurrently with the other. `handle_transition` is what
        # ultimately enqueues the email via Oban.
        old = Monitor.get_state(:calendar, integration.id, user.id)
        new = Monitor.update_health(old, {:error, :unauthorized, :hard})
        {_count, _nil} = Monitor.put_state(:calendar, integration.id, new)
        transition = Monitor.detect_transition(old, new)
        :ok = ResponseHandler.handle_transition(:calendar, integration, transition, new)
        send(parent, :done)
      end

      [t1, t2] = [Task.async(worker), Task.async(worker)]
      Task.await_many([t1, t2], 5_000)

      # Oban's `unique:` constraint on
      # [:action, :user_id, :integration_id, :integration_type] within
      # a 30-day window must coalesce the two concurrent inserts into
      # exactly one scheduled job. If this assertion ever goes to 2,
      # the unique constraint was silently broken.
      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{
            "action" => "send_integration_unhealthy_notification",
            "integration_id" => integration.id
          }
        )

      assert length(jobs) == 1,
             "Expected exactly one unhealthy notification job, got #{length(jobs)}"
    end
  end

  describe "transient failure grace period" do
    test "a burst of transient errors does not flip a healthy integration to unhealthy" do
      # Simulates a deploy rollout that causes ECONNREFUSED for a
      # stretch. The escalation ladder must absorb the first several
      # errors into the backoff ramp without incrementing failures or
      # firing a `:became_unhealthy` transition.
      initial = Monitor.initial_state()
      assert initial.status == :healthy
      assert initial.failures == 0
      # 30min initial check interval
      assert initial.backoff_ms == :timer.minutes(30)

      # Walk the ramp. Each hop must keep failures at 0 (no hard-
      # failure accounting yet) and status at :healthy — a deploy
      # blip must not paint a green integration red.
      {state_after_ramp, transitions} =
        Enum.reduce(1..5, {initial, []}, fn _i, {state, trans} ->
          new_state = Monitor.update_health(state, {:error, :econnrefused, :transient})

          transition = Monitor.detect_transition(state, new_state)

          assert new_state.failures == 0,
                 "grace-period step must not increment failures: got #{new_state.failures}"

          assert new_state.status == :healthy,
                 "grace-period step must not promote to :degraded/:unhealthy: got #{inspect(new_state.status)}"

          {new_state, [transition | trans]}
        end)

      # None of the five grace-period transitions may be a
      # `became_unhealthy` — that would be the false-positive the
      # plan is guarding against.
      refute Enum.any?(transitions, &match?({:became_unhealthy, _, :unhealthy}, &1)),
             "a transient-error burst must not produce a :became_unhealthy transition"

      # After the 5-step ramp the backoff must be at (or clamped to)
      # the 1-hour cap. This is the transition point: the next
      # transient error will start incrementing failures.
      assert state_after_ramp.backoff_ms == :timer.hours(1)
      assert state_after_ramp.last_error_class == :transient

      # Only after the backoff reaches the cap do sustained transient
      # failures start counting — eventually reaching `:unhealthy`.
      # This pins the other side of the boundary: grace is finite,
      # not infinite.
      state_beyond_grace =
        state_after_ramp
        |> Monitor.update_health({:error, :econnrefused, :transient})
        |> Monitor.update_health({:error, :econnrefused, :transient})
        |> Monitor.update_health({:error, :econnrefused, :transient})

      assert state_beyond_grace.status == :unhealthy
      assert state_beyond_grace.failures == 3
      assert %DateTime{} = state_beyond_grace.became_unhealthy_at
    end
  end
end
