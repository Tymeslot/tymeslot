defmodule TymeslotWeb.Live.Scheduling.SlotTimeLocaleTest do
  @moduledoc """
  The booking summary and the confirmation show the chosen time on the
  visitor's clock, in both themes.

  The chosen slot travels as its internal key ("5:30 PM"), which is also its
  identity: the URL `time` param, slot matching and the booking submission all
  read it verbatim. These screens used to print that key as it stood, so a
  visitor reading German picked "17:30" and was then shown "5:30 PM". The key
  must stay untouched and be formatted only where it is rendered.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :i18n
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  for {theme_id, theme_name} <- [{"1", "Quill"}, {"2", "Rhythm"}] do
    describe "#{theme_name}, visitor reading German" do
      setup do
        setup_host(unquote(theme_id))
      end

      @tag :capture_log
      test "the details step shows the chosen time on a 24-hour clock",
           %{conn: conn, profile: profile, date: date} do
        {:ok, view, html} =
          live(conn, "/#{profile.username}/chat/book?#{query(date, "5:30 PM")}")

        assert html =~ "17:30"
        refute html =~ "5:30 PM"

        # The key itself is untouched: it is what the submission sends.
        assert :sys.get_state(view.pid).socket.assigns.selected_time == "5:30 PM"
      end

      @tag :capture_log
      test "the confirmation shows the booked time on a 24-hour clock",
           %{conn: conn, profile: profile, date: date} do
        {:ok, _view, html} =
          live(conn, "/#{profile.username}/thank-you?#{query(date, "5:30 PM")}")

        assert html =~ "17:30"
        refute html =~ "5:30 PM"
      end
    end

    describe "#{theme_name}, visitor reading English" do
      setup do
        setup_host(unquote(theme_id))
      end

      @tag :capture_log
      test "the confirmation keeps the 12-hour clock",
           %{conn: conn, profile: profile, date: date} do
        {:ok, _view, html} =
          live(conn, "/#{profile.username}/thank-you?#{query(date, "5:30 PM", "en")}")

        assert html =~ "05:30 PM"
        refute html =~ "17:30"
      end
    end
  end

  defp query(date, time, locale \\ "de") do
    URI.encode_query(
      %{"date" => date, "time" => time, "timezone" => "Etc/UTC", "locale" => locale},
      :rfc3986
    )
  end

  defp setup_host(theme_id) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "clockhost#{theme_id}",
        booking_theme: theme_id,
        timezone: "Etc/UTC"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[20:00:00]
      )
    end)

    insert(:meeting_type,
      user: user,
      duration_minutes: 30,
      name: "Chat",
      is_active: true
    )

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile, date: Date.to_string(Date.add(Date.utc_today(), 3))}
  end
end
