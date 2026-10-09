defmodule TymeslotWeb.Live.Themes.MultipleLengthsFlowTest do
  @moduledoc """
  A meeting type can offer several lengths. The booker then picks one in a
  step of its own, between the meeting type and the calendar, in both themes;
  a type with one length never shows that step.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :scheduling

  import Ecto.Query, only: [from: 2]
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  # Gives the seeded 30-minute "Quick Chat" two further lengths.
  defp seed_several_lengths(theme_id, username) do
    %{user: user, profile: profile} = seed_booking_account(theme_id, username, "UTC")

    Repo.update_all(
      from(mt in MeetingTypeSchema, where: mt.user_id == ^user.id),
      set: [extra_lengths_minutes: [60, 15]]
    )

    %{user: user, profile: profile}
  end

  # A booking of the longer length, on a type whose primary length is shorter:
  # whatever grid the reschedule is offered must be the booked one.
  defp booked_hour(user) do
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
    start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

    insert(:meeting,
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id,
      attendee_email: "resched@example.com",
      attendee_timezone: "UTC",
      start_time: start,
      end_time: DateTime.add(start, 60, :minute),
      duration: 60,
      status: "confirmed"
    )
  end

  defp length_options(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("button[data-testid='length-option']", "data-minutes")
  end

  defp pick_first_slot_and_continue(view) do
    select_first_available_day(view)
    eventually(fn -> has_element?(view, "button[data-testid='time-slot']") end, timeout: 5000)

    slot = view |> render() |> Floki.parse_document!() |> first_slot_time()

    view
    |> element("button[data-testid='time-slot'][phx-value-time='#{slot}']")
    |> render_click()

    eventually(
      fn -> not has_element?(view, "button[data-testid='next-step'][disabled]") end,
      timeout: 5000
    )

    view |> element("button[data-testid='next-step']") |> render_click()
    eventually(fn -> has_element?(view, "form[data-testid='booking-form']") end, timeout: 5000)
  end

  for {theme_id, theme} <- [{"1", "quill"}, {"2", "rhythm"}] do
    describe "#{theme}" do
      @tag :capture_log
      test "asks for the length after the meeting type and books the one chosen",
           %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "lengths-#{unquote(theme)}")

        {:ok, view, html} = live(conn, ~p"/#{profile.username}")

        # The overview card shows the span rather than one length.
        assert html =~ "15–60 min"

        view
        |> element("button[data-testid='duration-option'][data-duration='quick-chat']")
        |> render_click()

        view |> element("button[data-testid='next-step']") |> render_click()

        assert has_element?(view, "[data-testid='length-step']")
        assert length_options(view) == ["15", "30", "60"]
        assert has_element?(view, "button[data-testid='next-step'][disabled]")

        view
        |> element("button[data-testid='length-option'][data-minutes='60']")
        |> render_click()

        view |> element("button[data-testid='next-step']") |> render_click()
        refute has_element?(view, "[data-testid='length-step']")

        pick_first_slot_and_continue(view)
        assert render(view) =~ "1 hour"

        submit_booking_form(view, unquote(theme_id), %{
          name: "Test Attendee",
          email: "lengths-#{unquote(theme)}@example.com",
          message: ""
        })

        eventually(fn -> has_element?(view, "[data-testid='confirmation-heading']") end,
          timeout: 10_000
        )

        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert meeting.duration == 60
        assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == 60
      end

      test "a direct link to the type opens on the length choice", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "direct-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat")

        assert has_element?(view, "[data-testid='length-step']")
        assert length_options(view) == ["15", "30", "60"]
      end

      test "a link naming an offered length skips the choice", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "preset-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat?minutes=60")

        refute has_element?(view, "[data-testid='length-step']")
        assert render(view) =~ "1 hour"
      end

      test "a link naming a length the type does not offer still asks", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "bogus-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat?minutes=45")

        assert has_element?(view, "[data-testid='length-step']")
      end

      test "the calendar leads back to the length choice", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "back-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat?minutes=60")

        view |> element("[data-testid='back-step']") |> render_click()

        assert has_element?(view, "[data-testid='length-step']")
        # The length chosen before is still selected.
        assert has_element?(view, "button[data-testid='length-option'][aria-pressed='true']")
      end

      test "a type with one length never shows the step", %{conn: conn} do
        %{profile: profile} =
          seed_booking_account(unquote(theme_id), "single-#{unquote(theme)}", "UTC")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

        view
        |> element("button[data-testid='duration-option'][data-duration='quick-chat']")
        |> render_click()

        view |> element("button[data-testid='next-step']") |> render_click()

        refute has_element?(view, "[data-testid='length-step']")
      end

      test "a reschedule keeps the booked length and skips the choice", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "resched-#{unquote(theme)}")

        meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
        start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            meeting_type_id: meeting_type.id,
            attendee_email: "resched@example.com",
            attendee_timezone: "UTC",
            start_time: start,
            end_time: DateTime.add(start, 60, :minute),
            duration: 60,
            status: "confirmed"
          )

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}?reschedule_meeting_uid=#{meeting.uid}")

        view
        |> element("button[data-testid='duration-option'][data-duration='quick-chat']")
        |> render_click()

        view |> element("button[data-testid='next-step']") |> render_click()

        refute has_element?(view, "[data-testid='length-step']")
        assert render(view) =~ "1 hour"
      end

      # `/:username/:slug` is where a locale switch mid-reschedule and an old
      # direct link with the uid appended both land. The type is resolved in
      # `mount` there, before `handle_params` has read the uid, so this is the
      # route on which a reschedule would otherwise be taken for a fresh
      # booking: asked for a length, or offered the primary one's grid.
      test "a reschedule entering at the type's own page keeps the booked length",
           %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "resched-slug-#{unquote(theme)}")

        meeting = booked_hour(user)

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}/quick-chat?reschedule_meeting_uid=#{meeting.uid}")

        refute has_element?(view, "[data-testid='length-step']")
        assert render(view) =~ "1 hour"
      end

      test "a reschedule entering at the booking form keeps the booked length", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "resched-book-#{unquote(theme)}")

        meeting = booked_hour(user)

        {:ok, view, _html} =
          live(
            conn,
            ~p"/#{profile.username}/quick-chat/book?reschedule_meeting_uid=#{meeting.uid}"
          )

        refute has_element?(view, "[data-testid='length-step']")
        assert render(view) =~ "1 hour"
      end
    end
  end
end
