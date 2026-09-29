defmodule TymeslotWeb.Dashboard.BookingsManagementAddGuestsTest do
  @moduledoc """
  The host adds colleagues to a booking that already exists, from the meetings
  list.

  Driven through the page rather than the handler, because the point of the
  feature is the button being there and reaching the right meeting.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import Mox

  import Ecto.Query

  alias Plug.Test
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user, profile: profile}
  end

  defp upcoming_meeting(user, attrs \\ %{}) do
    insert(
      :meeting,
      Map.merge(
        %{
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "John Doe",
          attendee_email: "john@example.com",
          start_time: DateTime.add(DateTime.utc_now(), 2, :day),
          end_time: DateTime.add(DateTime.utc_now(), 2 * 24 * 60 + 30, :minute)
        },
        attrs
      )
    )
  end

  defp stage(view, email) do
    view |> form("#stage-guest-form", %{"email" => email}) |> render_submit()
  end

  describe "adding guests" do
    test "invites the addresses the host enters", %{conn: conn, user: user} do
      meeting = upcoming_meeting(user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("#add-guests-#{meeting.id}") |> render_click()
      assert render(view) =~ "Add guest"

      stage(view, "one@example.com")
      stage(view, "two@example.com")
      view |> element("button", "Send invitation") |> render_click()

      assert [%{email: "one@example.com"}, %{email: "two@example.com"}] =
               GuestQueries.list_for_meeting(meeting.id)

      # Nothing is sent inline; the job carries it, so the dashboard never waits
      # on a mail server.
      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{
          "action" => "send_guest_invitations",
          "meeting_id" => meeting.id,
          "guest_ids" => meeting.id |> GuestQueries.list_for_meeting() |> Enum.map(& &1.id)
        }
      )
    end

    test "says so when every address is already invited, and queues nothing", %{
      conn: conn,
      user: user
    } do
      meeting = upcoming_meeting(user)
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["already@example.com"])

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#add-guests-#{meeting.id}") |> render_click()

      # The address is refused at the door rather than collected and dropped
      # later, so there is nothing to send and the button stays disabled.
      html = stage(view, "already@example.com")

      refute html =~ ~s(phx-value-email="already@example.com")
      assert length(GuestQueries.list_for_meeting(meeting.id)) == 1

      refute_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"action" => "send_guest_invitations", "meeting_id" => meeting.id}
      )
    end

    test "takes an address back off the list before anything is sent", %{conn: conn, user: user} do
      meeting = upcoming_meeting(user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#add-guests-#{meeting.id}") |> render_click()

      stage(view, "one@example.com")
      html = stage(view, "two@example.com")
      assert html =~ "one@example.com"

      html =
        view
        |> element(~s([phx-click="unstage_guest"][phx-value-email="one@example.com"]))
        |> render_click()

      refute html =~ "one@example.com"
      assert html =~ "two@example.com"

      view |> element("button", "Send invitation") |> render_click()

      assert ["two@example.com"] =
               meeting.id |> GuestQueries.list_for_meeting() |> Enum.map(& &1.email)
    end

    test "offers the button on a meeting type that does not allow guests", %{
      conn: conn,
      user: user
    } do
      # The setting governs the public booking form. Whom the host invites to
      # their own meeting afterwards is their business.
      meeting_type = insert(:meeting_type, user: user, allow_guests: false)
      meeting = upcoming_meeting(user, %{meeting_type_id: meeting_type.id})

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert has_element?(view, "#add-guests-#{meeting.id}")
    end

    test "refuses a meeting cancelled after the list was loaded", %{conn: conn, user: user} do
      meeting = upcoming_meeting(user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      Repo.update_all(from(m in MeetingSchema, where: m.id == ^meeting.id),
        set: [status: "cancelled"]
      )

      view |> element("#add-guests-#{meeting.id}") |> render_click()

      refute has_element?(view, "#stage-guest-form")
      assert render(view) =~ "Guests can no longer be added to this meeting"
    end

    test "withholds the button on a meeting that is being rescheduled", %{
      conn: conn,
      user: user
    } do
      meeting = upcoming_meeting(user, %{status: "reschedule_requested"})
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      refute has_element?(view, "#add-guests-#{meeting.id}")
    end

    test "withholds the button once the meeting is full", %{conn: conn, user: user} do
      meeting = upcoming_meeting(user)
      full = for n <- 1..Guests.max_guests(), do: "guest#{n}@example.com"
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, full)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      refute has_element?(view, "#add-guests-#{meeting.id}")
    end
  end

  describe "refusing an address" do
    setup %{conn: conn, user: user} do
      meeting = upcoming_meeting(user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#add-guests-#{meeting.id}") |> render_click()
      %{view: view, meeting: meeting}
    end

    test "says why an invalid address was not added", %{view: view} do
      refute stage(view, "not-an-email") =~ ~s(phx-value-email="not-an-email")
      assert render(view) =~ "not-an-email is not a valid email address."
    end

    # The form used to take anything shaped like an address and let the
    # domain drop what it did not accept on confirm, so the host was told the
    # guest was invited and nobody was. The dialog now asks the same rule.
    test "refuses an address the invitation itself would drop", %{view: view} do
      refute stage(view, "someone@example.invalidtld") =~
               ~s(phx-value-email="someone@example.invalidtld")

      assert render(view) =~ "someone@example.invalidtld is not a valid email address."
    end

    test "says the booker is already invited", %{view: view} do
      stage(view, "John@Example.com")

      assert render(view) =~ "john@example.com booked this meeting and is already invited."
    end

    test "says an address is already invited, on the meeting or on the list", %{
      view: view,
      meeting: meeting
    } do
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["there@example.com"])
      # The dialog lists the guests it was opened with, so it is reopened to
      # see the one just added.
      view |> element("#add-guests-#{meeting.id}") |> render_click()

      stage(view, "there@example.com")
      assert render(view) =~ "there@example.com is already invited."

      stage(view, "listed@example.com")
      stage(view, "Listed@example.com")
      html = render(view)

      assert html =~ "listed@example.com is already invited."
      assert length(Regex.scan(~r/phx-value-email="listed@example.com"/, html)) == 1
    end

    test "says there is no more room for a list pasted past the cap", %{
      view: view,
      meeting: meeting
    } do
      room = Guests.max_guests() - 1
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["first@example.com"])
      view |> element("#add-guests-#{meeting.id}") |> render_click()

      pasted = Enum.map_join(1..(room + 1), ", ", &"guest#{&1}@example.com")
      stage(view, pasted)
      html = render(view)

      assert html =~ "No more guests can be added to this meeting."
      assert html =~ ~s(phx-value-email="guest#{room}@example.com")
      refute html =~ ~s(phx-value-email="guest#{room + 1}@example.com")
    end
  end
end
