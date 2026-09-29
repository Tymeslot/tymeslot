defmodule Tymeslot.CalendarGrid.CalDAVChosenCalendarWriteTest do
  @moduledoc """
  Which CalDAV collection a grid create or one-off move is written to, when
  the organiser picks a writable calendar other than the booking one.

  The grid tests stop at the `:calendar_module` seam, and the CalDAV create
  test builds its client by hand; neither goes through `ClientManager` and a
  provider's `new/1`, which is where the chosen calendar used to be lost. This
  module points the seam back at the runtime module, so the write travels the
  whole way down and the URL the server receives can be read.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module do
        Application.put_env(:tymeslot, :calendar_module, previous_module)
      else
        Application.delete_env(:tymeslot, :calendar_module)
      end
    end)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/bookings/", "/cal/projects/"],
        default_booking_calendar_id: "/cal/bookings/",
        calendar_list: [
          %{id: "/cal/bookings/", path: "/cal/bookings/", name: "Bookings", selected: true},
          %{id: "/cal/projects/", path: "/cal/projects/", name: "Projects", selected: true}
        ]
      )

    %{user: user, integration: integration}
  end

  defp expect_put do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn url, _body, _headers, _opts ->
      send(test_pid, {:put, url})
      {:ok, %Req.Response{status: 201, body: "", headers: %{}}}
    end)
  end

  describe "creating an event from the grid on a non-booking calendar" do
    test "writes it to the chosen calendar and reports that calendar back", %{
      user: user,
      integration: integration
    } do
      expect_put()

      payload = %{
        creating: %{
          title: "Roadmap",
          integration_id: integration.id,
          calendar_id: "/cal/projects/",
          attendees: []
        },
        user_id: user.id,
        start_at: ~U[2026-10-08 09:00:00Z],
        end_at: ~U[2026-10-08 09:30:00Z]
      }

      assert {:ok, %{uid: uid} = result} = EventCreation.run_create_event(payload)

      assert_received {:put, url}
      assert url == "https://caldav.example.com/cal/projects/#{uid}.ics"

      # What the grid files the event's cached row under.
      assert result.written_calendar_id == "/cal/projects/"
    end
  end

  describe "moving a one-off event from the grid to a non-booking calendar" do
    test "writes it to the chosen calendar before deleting the original", %{
      user: user,
      integration: integration
    } do
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "standup",
          provider: "caldav",
          provider_calendar_id: "/cal/bookings/",
          provider_event_id: "/cal/bookings/standup.ics",
          summary: "Standup",
          start_at: ~U[2026-10-09 09:00:00.000000Z],
          end_at: ~U[2026-10-09 09:15:00.000000Z],
          all_day: false,
          etag: "\"etag-1\"",
          sync_state: "synced"
        )

      test_pid = self()
      expect_put()

      expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
        send(test_pid, {:delete, url})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, %{uid: uid}} =
               CalendarGrid.move_event(user.id, event, %{
                 integration: integration,
                 calendar_id: "/cal/projects/"
               })

      assert_received {:put, put_url}
      assert put_url == "https://caldav.example.com/cal/projects/#{uid}.ics"
      assert_received {:delete, "https://caldav.example.com/cal/bookings/standup.ics"}

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
      assert row.provider_calendar_id == "/cal/projects/"
    end
  end
end
