defmodule Tymeslot.Integrations.Calendar.Google.SyncCycleTest do
  @moduledoc """
  One Google sync cycle, run without Oban: what it reads, what it writes,
  and the outcome it hands its caller. Deciding what an outcome means for a
  job (flagging, snoozing, retrying) is the worker's, so none of it happens
  here.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Google.SyncCycle
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  defp integration(attrs \\ []) do
    inserted =
      insert(
        :calendar_integration,
        Keyword.merge(
          [
            provider: "google",
            google_sync_token: "valid-token",
            default_booking_calendar_id: "primary",
            needs_reauth: false,
            calendar_list: [%{"id" => "primary", "selected" => true, "name" => "Primary"}]
          ],
          attrs
        )
      )

    {:ok, loaded} = CalendarIntegrationQueries.get(inserted.id)
    loaded
  end

  defp google_event(id) do
    now = DateTime.utc_now()

    %{
      "id" => id,
      "iCalUID" => "#{id}@google.com",
      "status" => "confirmed",
      "summary" => "Planning",
      "start" => %{"dateTime" => now |> DateTime.add(1, :day) |> DateTime.to_iso8601()},
      "end" => %{
        "dateTime" =>
          now |> DateTime.add(1, :day) |> DateTime.add(1, :hour) |> DateTime.to_iso8601()
      }
    }
  end

  defp cached_uids(integration) do
    ProviderCalendarEventSchema
    |> Repo.all()
    |> Enum.filter(&(&1.calendar_integration_id == integration.id))
    |> Enum.map(& &1.uid)
  end

  describe "a delta read" do
    test "caches the delta's events and stores the next sync token" do
      integration = integration()

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [google_event("evt-1")], next_sync_token: "next-token"}}
      end)

      assert :ok = SyncCycle.run(integration)

      assert cached_uids(integration) == ["evt-1@google.com"]

      assert {:ok, %{google_sync_token: "next-token"}} =
               CalendarIntegrationQueries.get(integration.id)
    end

    test "bootstraps when Google expired the sync token" do
      integration = integration()

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :gone, "410"}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:ok, %{events: [google_event("evt-2")], next_sync_token: "fresh-token"}}
      end)

      assert :ok = SyncCycle.run(integration)
      assert cached_uids(integration) == ["evt-2@google.com"]
    end
  end

  # The delta and the bootstrap fail through one classification.
  for {phase, setup} <- [delta: :delta, bootstrap: :bootstrap] do
    describe "a failed #{phase} read" do
      @setup setup

      setup do
        %{integration: integration(), phase: @setup}
      end

      for {client_error, outcome} <- [
            {{:error, :unauthorized, "401"}, {:error, :unauthorized}},
            {{:error, :not_found, "404"}, {:error, :booking_calendar_missing}},
            {{:error, :not_a_calendar_user, "403"}, {:error, :not_a_calendar_user}},
            {{:error, :circuit_open}, {:error, :circuit_open}},
            {{:error, :too_many_pages, "Too many pages"},
             {:error, {:too_many_pages, "Too many pages"}}},
            {{:error, :server_error, "HTTP 503"}, {:error, "HTTP 503"}},
            {{:error, :rate_limited, "retry_after:30"}, {:error, "retry_after:30"}},
            {{:error, :timeout}, {:error, :timeout}}
          ] do
        @client_error client_error
        @outcome outcome

        test "#{inspect(client_error)} is #{inspect(outcome)}", %{
          integration: integration,
          phase: phase
        } do
          stub_failure(phase, @client_error)
          assert SyncCycle.run(integration) == @outcome
        end
      end

      test "leaves the integration's flag alone", %{integration: integration, phase: phase} do
        stub_failure(phase, {:error, :unauthorized, "401"})
        assert {:error, :unauthorized} = SyncCycle.run(integration)
        assert {:ok, %{needs_reauth: false}} = CalendarIntegrationQueries.get(integration.id)
      end
    end
  end

  defp stub_failure(:delta, error),
    do: expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration -> error end)

  defp stub_failure(:bootstrap, error) do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:error, :no_sync_token}
    end)

    expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration -> error end)
  end

  describe "secondary calendars" do
    setup do
      integration =
        integration(
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "work@example.com", "selected" => true, "name" => "Work"}
          ]
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "next-token"}}
      end)

      %{integration: integration}
    end

    test "an open breaker on one stops the cycle as :circuit_open", %{integration: integration} do
      expect(GoogleCalendarAPIMock, :list_events, fn _integration,
                                                     "work@example.com",
                                                     _start,
                                                     _end ->
        {:error, :circuit_open}
      end)

      assert {:error, :circuit_open} = SyncCycle.run(integration)
    end

    test "one deleted on Google is deselected and the cycle completes", %{
      integration: integration
    } do
      expect(GoogleCalendarAPIMock, :list_events, fn _integration,
                                                     "work@example.com",
                                                     _start,
                                                     _end ->
        {:error, :not_found, "404"}
      end)

      assert :ok = SyncCycle.run(integration)

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      refute Enum.any?(reloaded.calendar_list, &(&1.id == "work@example.com" and &1.selected))
    end
  end
end
