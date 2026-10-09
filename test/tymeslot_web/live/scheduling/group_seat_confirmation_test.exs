defmodule TymeslotWeb.Live.Scheduling.GroupSeatConfirmationTest do
  @moduledoc """
  A group booker's confirmation step, end to end: booking a seat through the
  public booking page offers "Add to calendar" for the booker's own seat (the
  file their emails invite them to), never the shared slot, whose uid would
  open the slot's public cancel and reschedule pages. Those pages, opened
  with a group meeting's uid anyway, send the visitor to the host's booking
  page with a message they can act on.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :bookings
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()
    :ok
  end

  for {theme_id, theme} <- [{"1", "Quill"}, {"2", "Rhythm"}] do
    @tag :capture_log
    test "#{theme}: Add to calendar downloads the booker's own seat, not the shared slot",
         %{conn: conn} do
      user = insert(:user)
      profile = bookable_profile(user, unquote(theme_id), "group-host-#{unquote(theme_id)}")

      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Workshop",
        is_active: true,
        max_participants: 3
      )

      view = navigate_to_booking_form(conn, profile, nil)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{"name" => "Ada Booker", "email" => "Ada@Example.com", "message" => ""}
      })
      |> render_submit()

      assert has_element?(view, "[data-testid='add-to-calendar']")

      slot = Repo.one!(MeetingSchema)
      assert [seat] = ParticipantQueries.list_live_for_meeting(slot.id)

      href = calendar_href(view)
      assert URI.parse(href).path == "/seat/#{seat.management_token}/calendar.ics"

      # The shared slot's uid is never handed to the booker.
      refute render(view) =~ slot.uid

      ics = build_conn() |> get(URI.parse(href).path) |> response(200)
      assert ics =~ "UID:#{seat.id}@"
      refute ics =~ "UID:#{slot.calendar_uid}@"
      assert ics =~ "mailto:ada@example.com"
    end
  end

  describe "the shared slot's own management pages" do
    setup do
      user = insert(:user)
      profile = bookable_profile(user, "1", "group-pages-host")
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      meeting =
        insert(:group_meeting,
          organizer_user: user,
          status: "confirmed",
          start_time: start_time,
          end_time: DateTime.add(start_time, 3600)
        )

      insert(:participant, meeting: meeting)

      %{profile: profile, meeting: meeting}
    end

    for action <- ["cancel", "reschedule"] do
      @tag :capture_log
      test "#{action} sends the visitor to the booking page with a message they can act on",
           %{conn: conn, profile: profile, meeting: meeting} do
        assert {:error, {:redirect, %{to: to, flash: flash}}} =
                 live(conn, "/#{profile.username}/meeting/#{meeting.uid}/#{unquote(action)}")

        assert to == "/#{profile.username}"

        assert flash["error"] ==
                 "This is a group session, so it cannot be changed from this link. " <>
                   "To cancel or move your spot, use the links in your confirmation email."

        assert Repo.get!(MeetingSchema, meeting.id).status == "confirmed"
      end
    end
  end

  defp calendar_href(view) do
    [href] =
      view
      |> element("[data-testid='add-to-calendar']")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("href")

    href
  end
end
