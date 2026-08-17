defmodule Tymeslot.Workers.SyncLinkWriteBackHealthTest do
  @moduledoc """
  A target calendar that will not accept mirror writes becomes visibly
  unhealthy.

  Without this the failure is silent in the only place it matters. Mirror
  write-backs are best-effort by construction — a failed write never fails the
  inbound sync that triggered it, and the reconcile sweep quietly retries — so
  an organiser whose target calendar has had its token revoked sees exactly
  what they saw when it worked: nothing. The busy blocks simply stop appearing,
  and the first they learn of it is a double booking.

  Surfacing goes through the health-check domain that already exists and is
  already integration-keyed, so the hub badge lights up with no second store
  and no second breaker. `HealthCheck.attention_status/2` is the ladder the
  dashboard reads, and it is asserted here rather than only the stored row:
  writing a row nothing renders is how the first version of a feature like this
  ships broken.

  Only an *exhausted* job marks the integration. A single failed attempt is a
  timeout or a rate limit, and Oban's whole retry ladder exists because those
  recover on their own; marking on the first one would put the badge up for
  every transient blip on every event.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  defp cached_event(source) do
    insert(:provider_calendar_event,
      calendar_integration: source,
      uid: "source-uid-1",
      summary: "Board meeting",
      provider: source.provider,
      provider_event_id: "source-pid-1",
      all_day: false,
      start_at: ~U[2026-07-03 09:00:00Z],
      end_at: ~U[2026-07-03 10:00:00Z]
    )
  end

  defp args(link), do: %{"sync_link_id" => link.id, "source_uid" => "source-uid-1"}

  defp upsert_args(link), do: Map.put(args(link), "operation", "upsert")

  # Read from the worker rather than restated, so raising `max_attempts` cannot
  # leave these tests asserting on an attempt that is no longer the last one.
  defp final_attempt,
    do: Keyword.fetch!(SyncLinkWriteBackWorker.__opts__(), :max_attempts)

  describe "a target that keeps refusing writes" do
    test "is marked unhealthy once the job has exhausted its attempts", %{
      source: source,
      target: target,
      link: link
    } do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :invalid_grant}
      end)

      assert {:error, :invalid_grant} ==
               perform_job(SyncLinkWriteBackWorker, upsert_args(link), attempt: final_attempt())

      health = HealthCheck.get_health_status(:calendar, target.id)
      assert health.status == :unhealthy

      # The badge, not just the row: this is what the hub actually reads.
      assert HealthCheck.attention_status(target, health) == :unhealthy
    end

    test "marks the TARGET, not the source whose event triggered the write", %{
      source: source,
      link: link
    } do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :invalid_grant}
      end)

      perform_job(SyncLinkWriteBackWorker, upsert_args(link), attempt: final_attempt())

      # The source calendar is answering perfectly well — it is where the event
      # came from. Blaming it would send the organiser to reconnect the wrong
      # calendar.
      assert is_nil(HealthCheck.get_health_status(:calendar, source.id))
    end

    test "a failed withdrawal marks the target too", %{target: target, link: link} do
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :invalid_grant}
      end)

      assert {:error, :invalid_grant} ==
               perform_job(
                 SyncLinkWriteBackWorker,
                 Map.put(args(link), "operation", "delete"),
                 attempt: final_attempt()
               )

      assert HealthCheck.get_health_status(:calendar, target.id).status == :unhealthy
    end
  end

  describe "a target that is merely having a bad minute" do
    test "is left alone while attempts remain", %{source: source, target: target, link: link} do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} ==
               perform_job(SyncLinkWriteBackWorker, upsert_args(link), attempt: 1)

      # No row at all: an attempt that Oban is about to retry says nothing
      # about the target, so nothing about the target is recorded.
      assert is_nil(HealthCheck.get_health_status(:calendar, target.id))
    end

    test "a successful write leaves the health row untouched", %{
      source: source,
      target: target,
      link: link
    } do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      assert :ok ==
               perform_job(SyncLinkWriteBackWorker, upsert_args(link), attempt: final_attempt())

      assert is_nil(HealthCheck.get_health_status(:calendar, target.id))
    end

    test "a discard is not a failure and never marks the target", %{
      user: user,
      source: source
    } do
      ics_target = insert(:calendar_integration, user: user, provider: "ics_url")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: ics_target.id
        )

      cached_event(source)

      assert {:discard, :target_is_read_only} ==
               perform_job(SyncLinkWriteBackWorker, upsert_args(link), attempt: final_attempt())

      assert is_nil(HealthCheck.get_health_status(:calendar, ics_target.id))
    end
  end
end
