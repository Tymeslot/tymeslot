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

  alias Plug.Test
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests

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
        args: %{"action" => "send_guest_invitations", "meeting_id" => meeting.id}
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

      refute html =~ ~s(id="stage-guest-chip")
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

    test "withholds the button once the meeting is full", %{conn: conn, user: user} do
      meeting = upcoming_meeting(user)
      full = for n <- 1..Guests.max_guests(), do: "guest#{n}@example.com"
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, full)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      refute has_element?(view, "#add-guests-#{meeting.id}")
    end
  end
end
