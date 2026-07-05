defmodule Tymeslot.Workers.ColourWriteBackWorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers

  import Mox

  setup :verify_on_exit!

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Workers.ColourWriteBackWorker

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "google")
    %{user: user, integration: integration}
  end

  defp cached_event(integration, attrs) do
    defaults = [
      calendar_integration: integration,
      uid: "uid-1",
      summary: "Meeting",
      provider: integration.provider,
      provider_event_id: "pid-1",
      raw_ical: "BEGIN:VEVENT\nUID:uid-1\nRRULE:FREQ=WEEKLY\nEND:VEVENT",
      all_day: false,
      start_at: ~U[2026-07-03 10:00:00Z],
      end_at: ~U[2026-07-03 11:00:00Z]
    ]

    insert(:provider_calendar_event, Keyword.merge(defaults, attrs))
  end

  describe "enqueue via the Calendar context" do
    test "set_event_colour enqueues a write-back", %{user: user, integration: integ} do
      {:ok, _override} =
        Calendar.set_event_colour(user.id, {:external, integ.id, "uid-1"}, "blueberry")

      assert_enqueued(
        worker: ColourWriteBackWorker,
        args: %{
          "integration_id" => integ.id,
          "uid" => "uid-1",
          "user_id" => user.id,
          "colour" => "blueberry"
        }
      )
    end

    test "clear_event_colour does not enqueue a write-back", %{user: user, integration: integ} do
      :ok = Calendar.clear_event_colour(user.id, {:external, integ.id, "uid-1"})
      refute_enqueued(worker: ColourWriteBackWorker)
    end
  end

  describe "perform/1" do
    test "pushes only the colour to the provider, never a full-field payload", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1")

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", event_data, {integ_id, user_id} ->
        assert event_data.colour_only == true
        assert event_data.colour == "blueberry"
        assert event_data.provider_event_id == "pid-1"
        assert event_data.raw_ical =~ "RRULE:FREQ=WEEKLY"
        # Timing/summary/description/location must NOT be sent — a full-field
        # payload would wipe recurrence/attendees/alarms on a full replace.
        refute Map.has_key?(event_data, :summary)
        refute Map.has_key?(event_data, :start_time)
        refute Map.has_key?(event_data, :description)
        assert integ_id == integ.id
        assert user_id == user.id
        :ok
      end)

      assert :ok =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end

    test "returns an error so Oban retries when the provider write fails", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1")

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", _event_data, _context ->
        {:error, :read_only}
      end)

      assert {:error, :read_only} =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end

    test "discards for an outlook event (no per-event colour)", %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "outlook")
      cached_event(integration, uid: "uid-o", provider: "outlook")

      assert {:discard, :provider_has_no_event_colour} =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integration.id,
                 "uid" => "uid-o",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end

    test "discards when the event is no longer cached", %{user: user, integration: integ} do
      assert {:discard, :event_not_cached} =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "missing",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end
  end
end
