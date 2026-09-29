defmodule Tymeslot.Integrations.Calendar.SyncErrorTrackingTest do
  @moduledoc """
  A failure writing a sync's events to the local cache is a bug or an
  outage. `Sync` returns it as `{:error, _}` so the sync run can roll back,
  and records it in ErrorTracker with the integration it concerned.
  """

  # async: false: ErrorTracker's `enabled` switch and the telemetry handler
  # are global.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Sync

  @telemetry_handler "sync-error-tracking-test-occurrences"

  @doc false
  @spec forward_occurrence([atom()], map(), map(), pid()) :: :ok
  def forward_occurrence(_event, _measurements, _metadata, test_pid) do
    send(test_pid, :occurrence_recorded)
    :ok
  end

  setup do
    with_config(:error_tracker, enabled: true)

    :ok =
      :telemetry.attach(
        @telemetry_handler,
        [:error_tracker, :occurrence, :new],
        &__MODULE__.forward_occurrence/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(@telemetry_handler) end)

    %{integration: insert(:calendar_integration, user: insert(:user))}
  end

  defp recorded_errors, do: Error |> Repo.all() |> Repo.preload(:occurrences)

  defp event(integration) do
    now = DateTime.utc_now(:microsecond)

    CalendarEvent.new!(%{
      uid: "sync-error-evt",
      calendar_integration_id: integration.id,
      provider: :caldav,
      provider_calendar_id: "/cal/primary",
      provider_event_id: "evt-sync-error",
      all_day: false,
      start_at: now,
      end_at: DateTime.add(now, 3600, :second),
      synced_at: now
    })
  end

  test "an upsert that raises inside the sync's transaction is recorded despite the rollback",
       %{integration: integration} do
    # Stands in for the database refusing the write. Created inside the
    # sandbox transaction, so rolled back with the test.
    Repo.query!("""
    CREATE FUNCTION fail_provider_event_insert() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'provider events unavailable'; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER fail_provider_event_insert BEFORE INSERT ON provider_calendar_events
    FOR EACH ROW EXECUTE FUNCTION fail_provider_event_insert()
    """)

    capture_log(fn ->
      assert {:error, _reason} =
               Repo.transaction(fn ->
                 {:error, reason} = Sync.upsert_cache(integration, [event(integration)])
                 Repo.rollback(reason)
               end)

      assert_receive :occurrence_recorded, 2_000
    end)

    assert [%Error{kind: "Elixir.Postgrex.Error"} = error] = recorded_errors()

    assert [%{context: %{"calendar_integration_id" => id, "event_count" => 1}}] =
             error.occurrences

    assert id == integration.id
  end

  test "a role refresh that raises is recorded", %{integration: integration} do
    capture_log(fn ->
      assert {:error, _message} = Sync.full_refresh_for_role(integration, "no_such_role", [])
    end)

    assert [%Error{kind: "Elixir.FunctionClauseError"} = error] = recorded_errors()

    assert [%{context: %{"calendar_integration_id" => id, "role" => "no_such_role"}}] =
             error.occurrences

    assert id == integration.id
  end
end
