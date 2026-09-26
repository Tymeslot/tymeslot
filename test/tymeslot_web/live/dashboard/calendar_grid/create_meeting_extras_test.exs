defmodule TymeslotWeb.Dashboard.CalendarGrid.CreateMeetingExtrasTest do
  @moduledoc """
  What the host can give a quick-add meeting beyond a time and one guest: more
  guests, a message, and the language all of them are written to.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(), locale: "de")
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp open_form(lv) do
    lv |> element("#calendar-grid") |> render_hook("show_create_form", %{})
  end

  defp hook(lv, event, params) do
    lv |> element("#calendar-grid") |> render_hook(event, params)
  end

  # Submitting the form the host types into, rather than handing the handler
  # the payload it expects — the wiring between the two is the thing that
  # broke once already.
  defp add_guest(lv, email) do
    lv |> form("#create-add-guest-form", %{"email" => email}) |> render_submit()
  end

  defp fill_guest(lv) do
    hook(lv, "update_create_guest_name", %{"value" => "Ada Lovelace"})
    hook(lv, "update_create_guest_email", %{"value" => "ada@example.com"})
  end

  # Creation runs in a supervised task, so the row appears a moment after the
  # event returns. The existing tests for this modal sidestep that by sending
  # the result themselves; these go through the real path, so they wait for it.
  defp created_meeting(tries \\ 50) do
    case Repo.one(MeetingSchema) do
      nil when tries > 0 ->
        Process.sleep(20)
        created_meeting(tries - 1)

      meeting ->
        meeting
    end
  end

  describe "more guests" do
    test "invites everyone the host adds beside the main guest", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      add_guest(lv, "One@Example.com")
      add_guest(lv, "two@example.com")
      hook(lv, "save_event", %{})

      meeting = created_meeting()
      assert meeting.attendee_email == "ada@example.com"

      assert ["one@example.com", "two@example.com"] =
               meeting.id |> GuestQueries.list_for_meeting() |> Enum.map(& &1.email)
    end

    test "refuses the main guest's own address and repeats of one already added", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      add_guest(lv, "ada@example.com")
      add_guest(lv, "one@example.com")
      html = add_guest(lv, "one@example.com")

      # One chip, for the one address that was addable.
      assert html =~ "one@example.com"
      hook(lv, "save_event", %{})

      assert ["one@example.com"] =
               created_meeting().id |> GuestQueries.list_for_meeting() |> Enum.map(& &1.email)
    end

    test "stops offering the field once the cap is reached", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      for n <- 1..Guests.max_guests() do
        add_guest(lv, "guest#{n}@example.com")
      end

      refute has_element?(lv, "#create-add-guest-form")

      # And the one past the cap is not taken even if the event arrives anyway.
      hook(lv, "add_create_guest", %{"email" => "late@example.com"})
      hook(lv, "save_event", %{})

      assert length(GuestQueries.list_for_meeting(created_meeting().id)) == Guests.max_guests()
    end
  end

  describe "the message" do
    test "reaches the meeting, where the card and the guests' emails read it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      lv
      |> element("#create-meeting-message")
      |> render_blur(%{"value" => "  Bring the slides.  "})

      hook(lv, "save_event", %{})

      # `attendee_message`, not `description`: that one carries the meeting
      # type's own text on a booked meeting and is read by nothing but the
      # calendar entry, so a note left there would never reach the guest.
      assert created_meeting().attendee_message == "Bring the slides."
    end

    test "is optional", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)
      hook(lv, "save_event", %{})

      assert created_meeting().attendee_message == nil
    end
  end

  describe "the language" do
    test "defaults to the host's own and is stored on the meeting", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)
      hook(lv, "save_event", %{})

      assert created_meeting().attendee_locale == "de"
    end

    test "follows the host's choice for this meeting", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      # Driven through the control itself, not by handing the handler the
      # payload it expects: what the browser sends is the thing under test.
      lv
      |> element("#create-meeting-locale-form")
      |> render_change(%{"locale" => "fr"})

      hook(lv, "save_event", %{})

      assert created_meeting().attendee_locale == "fr"
    end

    test "ignores a language the instance does not support", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      hook(lv, "update_create_locale", %{"locale" => "kl"})
      hook(lv, "save_event", %{})

      assert created_meeting().attendee_locale == "de"
    end
  end
end
