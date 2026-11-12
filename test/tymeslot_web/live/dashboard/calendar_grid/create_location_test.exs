defmodule TymeslotWeb.Dashboard.CalendarGrid.CreateLocationTest do
  @moduledoc """
  Quick add's location field: none, one of the host's saved locations, or
  a place typed in. A meeting is created at it, driven through the modal as
  the host uses it; a plain event carries it as the text its calendar entry
  gets.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateExecution

  describe "a meeting" do
    setup %{conn: conn} do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, timezone: "Etc/UTC")
      venue = insert(:venue, user: user, name: "Head office", description: "Main St 1")
      insert(:venue, name: "Someone else's office")

      conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

      # Without a writable calendar the modal opens straight in meeting mode.
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#calendar-grid") |> render_hook("show_create_form", %{})

      lv |> element("#create-meeting-guest-name") |> render_blur(%{"value" => "Ada Lovelace"})
      lv |> element("#create-meeting-guest-email") |> render_blur(%{"value" => "ada@example.com"})

      {:ok, lv: lv, venue: venue}
    end

    defp choose(lv, params),
      do: lv |> form("#create-location-form") |> render_change(params)

    defp create_meeting(lv) do
      lv |> element("#create-event-modal button", "Create") |> render_click()
      eventually(fn -> Repo.one(MeetingSchema) end, timeout: 5000)
    end

    test "offers no location, the host's saved locations and a place of their own", %{lv: lv} do
      html = render(lv)

      assert has_element?(lv, "#create-location-choice option[value='']", "No location")
      assert html =~ "Head office"
      refute html =~ "Someone else&#39;s office"
      assert has_element?(lv, "#create-location-choice option[value='custom']")
      # The text field appears only for a place of their own.
      refute has_element?(lv, "#create-location-custom")
    end

    test "is held at the saved location chosen", %{lv: lv, venue: venue} do
      choose(lv, %{"location_choice" => "venue:#{venue.id}"})

      meeting = create_meeting(lv)

      assert meeting.location == "Head office (Main St 1)"
      assert meeting.location_kind == :in_person
      assert meeting.venue_id == venue.id
    end

    test "is held at a place typed in", %{lv: lv} do
      choose(lv, %{"location_choice" => "custom"})
      assert has_element?(lv, "#create-location-custom")

      choose(lv, %{"location_choice" => "custom", "location_custom" => "Café Central, 2nd floor"})

      meeting = create_meeting(lv)

      assert meeting.location == "Café Central, 2nd floor"
      assert meeting.location_kind == :custom
    end

    test "keeps the form open when Enter is pressed in the text field", %{lv: lv} do
      choose(lv, %{"location_choice" => "custom"})

      lv
      |> form("#create-location-form")
      |> render_submit(%{"location_choice" => "custom", "location_custom" => "Room 4.12"})

      assert has_element?(lv, "#create-location-custom[value='Room 4.12']")
      assert create_meeting(lv).location == "Room 4.12"
    end

    test "has no location when none is chosen", %{lv: lv} do
      meeting = create_meeting(lv)

      assert meeting.location == nil
      assert meeting.location_kind == nil
    end
  end

  describe "a plain event" do
    test "carries a saved location as the text of its calendar entry" do
      user = insert(:user)
      venue = insert(:venue, user: user, name: "Head office", description: "Main St 1")

      socket = event_socket(user, [venue], %{location_choice: "venue:#{venue.id}"})
      {:noreply, _socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_receive {:execute_create_event, payload}
      assert payload.creating.location == "Head office (Main St 1)"
    end

    test "carries a place typed in as written" do
      user = insert(:user)

      socket =
        event_socket(user, [], %{location_choice: "custom", location_custom: " Room 4.12 "})

      {:noreply, _socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_receive {:execute_create_event, payload}
      assert payload.creating.location == "Room 4.12"
    end

    test "refuses a saved location that is no longer the host's" do
      user = insert(:user)

      socket = event_socket(user, [], %{location_choice: "venue:123"})
      {:noreply, socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_receive {:flash, {:error, "That location can no longer be used." <> _rest}}
      refute_receive {:execute_create_event, _payload}
      refute socket.assigns.saving_event
    end
  end

  defp event_socket(user, venues, location) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        user_timezone: "Etc/UTC",
        saving_event: false,
        owned_integration_ids: MapSet.new([42]),
        venues: venues,
        creating_event:
          Map.merge(
            %{
              title: "Workshop",
              integration_id: 42,
              calendar_id: "primary",
              date: "2026-12-07",
              end_date: "2026-12-07",
              start_hour: 9,
              start_minute: 0,
              end_hour: 10,
              end_minute: 0,
              all_day: false,
              attendees: [],
              reminders: [],
              recurrence_rule: nil,
              video_integration_id: nil
            },
            location
          )
      }
    }
  end
end
