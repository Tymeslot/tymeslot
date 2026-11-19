defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMeetingOptionsTest do
  @moduledoc """
  A Tymeslot meeting's options in the side panel's New event state, beside
  the guest's name, language and reminders: whether the first guest is the
  meeting's main participant, and where it takes place (none, one of the
  organiser's saved locations, or a place typed in). Without a main
  participant the host manages the meeting alone, every guest is an equal
  guest, and the meeting needs a title of its own.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Venues

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:more_options", %{
      "draft" => "d1",
      "title" => "",
      "start" => "2026-10-15T13:00",
      "end" => "2026-10-15T14:00",
      "all_day" => false,
      "calendar" => "#{context.integration.id}:work",
      "location" => "",
      "guests" => ["ada@example.com", "grace@example.com"],
      "free" => false
    })

    assert_reply(lv, %{opened: true})
    render_change(new_form(lv), %{"meeting" => "true"})

    Map.put(context, :lv, lv)
  end

  defp new_form(lv), do: form(lv, "#calendar-panel-new-form")

  defp trace(lv), do: :erlang.trace(lv.pid, true, [:receive])

  defp submit_meeting(lv, params) do
    trace(lv)
    render_submit(new_form(lv), Map.put(params, "intent", "create"))
  end

  defp booked do
    assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}
    params
  end

  defp nothing_booked do
    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}},
                   100
  end

  describe "main participant" do
    test "is on by default, with the guest's name asked for", %{lv: lv} do
      assert has_element?(lv, "#calendar-panel-meeting-main-participant[checked]")
      assert has_element?(lv, "#calendar-panel-meeting-guest-name")

      assert has_element?(
               lv,
               "#calendar-panel-meeting-main-participant-hint",
               "The main participant can move or cancel the meeting."
             )
    end

    test "turned off, the guest's name gives way and the hint says who manages it", %{lv: lv} do
      render_change(new_form(lv), %{"main_participant" => "false"})

      refute has_element?(lv, "#calendar-panel-meeting-guest-name")

      assert has_element?(
               lv,
               "#calendar-panel-meeting-main-participant-hint",
               "Only you can move or cancel the meeting."
             )
    end

    test "turned off, every guest is invited as an equal guest of a meeting the host manages",
         %{lv: lv} do
      render_change(new_form(lv), %{"main_participant" => "false"})
      submit_meeting(lv, %{"title" => "Planning"})

      params = booked()

      assert %{
               title: "Planning",
               managed_by_host: true,
               guest_emails: ["ada@example.com", "grace@example.com"]
             } = params

      refute Map.has_key?(params, :attendee_name)

      meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: @task_timeout)
      assert meeting.managed_by_host
      assert meeting.title == "Planning"

      assert ["ada@example.com", "grace@example.com"] =
               meeting.id
               |> GuestQueries.list_for_meeting()
               |> Enum.map(& &1.email)
               |> Enum.sort()
    end

    test "turned off, a meeting without a title is not booked, and the panel says why", %{lv: lv} do
      render_change(new_form(lv), %{"main_participant" => "false"})
      submit_meeting(lv, %{"title" => "  "})

      nothing_booked()

      assert render(lv) =~
               "Add a title. A meeting without a main participant is known by its title."
    end

    test "on, the first guest is the one the meeting is with", %{lv: lv} do
      submit_meeting(lv, %{"guest_name" => "Ada Lovelace"})

      assert %{
               attendee_name: "Ada Lovelace",
               attendee_email: "ada@example.com",
               guest_emails: ["grace@example.com"]
             } = params = booked()

      refute Map.has_key?(params, :managed_by_host)
    end
  end

  describe "location" do
    test "offers the organiser's saved locations and a place typed in", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      venue = insert(:venue, user: user, name: "Head office")
      insert(:venue, name: "Someone else's office")

      # Saved locations are read as the panel opens.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:more_options", %{
        "draft" => "d2",
        "start" => "2026-10-15T13:00",
        "end" => "2026-10-15T14:00",
        "calendar" => "#{integration.id}:work",
        "guests" => ["ada@example.com"]
      })

      render_change(new_form(lv), %{"meeting" => "true"})

      assert has_element?(
               lv,
               ~s(#calendar-panel-meeting-location option[value="venue:#{venue.id}"]),
               "Head office"
             )

      refute render(lv) =~ "Someone else&#39;s office"
      assert has_element?(lv, ~s(#calendar-panel-meeting-location option[value="custom"]))
      refute has_element?(lv, "#calendar-panel-meeting-location-custom")
    end

    test "a saved location goes with the meeting", %{user: user, lv: lv} do
      venue = insert(:venue, user: user, name: "Head office")

      submit_meeting(lv, %{
        "guest_name" => "Ada Lovelace",
        "location_choice" => "venue:#{venue.id}"
      })

      venue_id = venue.id
      assert %{location: {:venue, ^venue_id}} = booked()

      meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: @task_timeout)
      assert meeting.venue_id == venue.id
      assert meeting.location == Venues.display(venue)
    end

    test "a place typed in goes with the meeting", %{lv: lv} do
      render_change(new_form(lv), %{"location_choice" => "custom"})
      assert has_element?(lv, "#calendar-panel-meeting-location-custom")

      submit_meeting(lv, %{
        "guest_name" => "Ada Lovelace",
        "location_choice" => "custom",
        "location_custom" => " Room 4, second floor "
      })

      assert %{location: {:custom, "Room 4, second floor"}} = booked()

      meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: @task_timeout)
      assert meeting.location == "Room 4, second floor"
    end

    test "a Place typed before the box was ticked becomes the meeting's location", %{lv: lv} do
      render_change(new_form(lv), %{"meeting" => "false"})
      render_change(new_form(lv), %{"location" => "Café Rose"})
      render_change(new_form(lv), %{"meeting" => "true", "location" => "Café Rose"})

      assert has_element?(
               lv,
               ~s(#calendar-panel-meeting-location-custom[value="Café Rose"])
             )

      submit_meeting(lv, %{"guest_name" => "Ada Lovelace"})

      assert %{location: {:custom, "Café Rose"}} = booked()
    end

    test "a Place longer than a meeting takes is refused with the meeting's limit", %{lv: lv} do
      place = String.duplicate("a", 600)
      render_change(new_form(lv), %{"meeting" => "false"})
      render_change(new_form(lv), %{"location" => place})
      render_change(new_form(lv), %{"meeting" => "true", "location" => place})

      submit_meeting(lv, %{"guest_name" => "Ada Lovelace"})

      nothing_booked()

      assert has_element?(
               lv,
               "#calendar-panel [role=status]",
               "The place is too long for a meeting. Keep it under 500 characters."
             )
    end

    test "a saved location chosen for the event and deleted since does not block the meeting",
         %{user: user, lv: lv} do
      venue = insert(:venue, user: user, name: "Head office")
      render_change(new_form(lv), %{"meeting" => "false"})

      # The panel read the saved locations as it opened, before this one.
      lv
      |> element("#calendar-panel-new-form")
      |> render_change(%{"location_venue" => "#{venue.id}"})

      render_change(new_form(lv), %{"meeting" => "true"})
      render_change(new_form(lv), %{"location_choice" => ""})

      Repo.delete!(venue)

      # Nor does it refuse the meeting drawn on the grid as the form changes.
      render_change(new_form(lv), %{"guest_name" => "Ada Lovelace"})

      refute has_element?(
               lv,
               "#calendar-panel [role=status]",
               "That location can no longer be used."
             )

      submit_meeting(lv, %{"guest_name" => "Ada Lovelace", "location_choice" => ""})

      assert %{location: nil} = booked()
    end

    test "a meeting location already chosen is kept when the box is ticked again", %{lv: lv} do
      render_change(new_form(lv), %{
        "location_choice" => "custom",
        "location_custom" => "Room 4"
      })

      render_change(new_form(lv), %{"meeting" => "false"})
      render_change(new_form(lv), %{"meeting" => "true", "location" => "Café Rose"})

      submit_meeting(lv, %{"guest_name" => "Ada Lovelace"})

      assert %{location: {:custom, "Room 4"}} = booked()
    end

    test "no choice, or a place left blank, books it without one", %{lv: lv} do
      submit_meeting(lv, %{"guest_name" => "Ada Lovelace", "location_choice" => "custom"})

      assert %{location: nil} = booked()
    end

    test "a saved location deleted after Create, before the booking read it, is named in the flash",
         %{user: user, lv: lv} do
      venue = insert(:venue, user: user, name: "Head office")

      # What the panel hands the dashboard for a meeting at the venue, which
      # is deleted before the booking reads it.
      params = %{
        title: "Meeting with Ada Lovelace",
        start_time: ~U[2026-10-15 12:00:00Z],
        end_time: ~U[2026-10-15 13:00:00Z],
        attendee_name: "Ada Lovelace",
        attendee_email: "ada@example.com",
        attendee_timezone: "Europe/London",
        guest_emails: [],
        organizer_user_id: user.id,
        location: {:venue, venue.id}
      }

      Repo.delete!(venue)
      send(lv.pid, {:execute_create_ad_hoc_meeting, make_ref(), params})

      eventually(
        fn ->
          render(lv) =~ "That location can no longer be used. Please choose another one."
        end,
        timeout: @task_timeout
      )

      assert Repo.all(MeetingSchema) == []
    end

    test "someone else's saved location is refused, and nothing is booked", %{lv: lv} do
      venue = insert(:venue, name: "Someone else's office")

      submit_meeting(lv, %{
        "guest_name" => "Ada Lovelace",
        "location_choice" => "venue:#{venue.id}"
      })

      nothing_booked()
      assert render(lv) =~ "That location can no longer be used. Please choose another one."
    end
  end
end
