defmodule Tymeslot.CalendarGrid.EventCreationMonthEndTest do
  @moduledoc """
  A monthly series on a day some months lack is refused for Outlook, which
  would move those months' events to their last day (see
  `Outlook.RecurrenceConverter`), before anything is written or a video room
  is made. `Calendar.Events` points at `Tymeslot.CalendarMock`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CreatedEvent

  setup :verify_on_exit!

  describe "run_create_event/1 — a monthly series on a day some months lack" do
    defp month_end_payload(integration, user, start_at, timezone) do
      integration
      |> month_end_payload(user)
      |> Map.merge(%{
        start_at: start_at,
        end_at: DateTime.add(start_at, 3600),
        timezone: timezone
      })
    end

    defp month_end_payload(integration, user) do
      %{
        creating: %{
          title: "Month-end close",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: [],
          recurrence_rule: "FREQ=MONTHLY"
        },
        user_id: user.id,
        start_at: ~U[2026-01-31 09:00:00Z],
        end_at: ~U[2026-01-31 10:00:00Z]
      }
    end

    # No `create_event` expectation: a write reaching the calendar fails the test.
    test "is refused for Outlook before anything is written" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "outlook")

      assert EventCreation.run_create_event(month_end_payload(integration, user)) ==
               {:error, %{reason: :day_missing_in_some_months, retry: :not_queued}}
    end

    # 20:00 on the 28th in New York is the 29th in UTC. Outlook writes the
    # series from the organiser's own date, the 28th, which every month has.
    test "reads the start date in the organiser's zone west of UTC" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "outlook")

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.series_timezone == "America/New_York"
        {:ok, CreatedEvent.new(event_data.uid)}
      end)

      payload =
        month_end_payload(integration, user, ~U[2026-01-29 01:00:00Z], "America/New_York")

      assert {:ok, _result} = EventCreation.run_create_event(payload)
    end

    # 08:00 on the 29th in Tokyo is still the 28th in UTC; the series is the
    # 29th's, which February lacks. Refused before a video room is asked for
    # or anything reaches the calendar (no `create_event` expectation).
    test "reads the start date in the organiser's zone east of UTC" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "outlook")

      video = insert(:video_integration, user: user, provider: "mirotalk")
      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        send(test_pid, {:room_requested, url})
        {:error, :unexpected}
      end)

      payload =
        integration
        |> month_end_payload(user, ~U[2026-01-28 23:00:00Z], "Asia/Tokyo")
        |> put_in([:creating, :video_integration_id], video.id)

      assert EventCreation.run_create_event(payload) ==
               {:error, %{reason: :day_missing_in_some_months, retry: :not_queued}}

      refute_received {:room_requested, _url}
    end

    test "is written to a calendar that skips the short months itself" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "caldav")

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.recurrence_rule == "FREQ=MONTHLY"
        {:ok, CreatedEvent.new(event_data.uid)}
      end)

      assert {:ok, _result} = EventCreation.run_create_event(month_end_payload(integration, user))
    end
  end
end
