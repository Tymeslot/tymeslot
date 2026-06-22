defmodule TymeslotWeb.Live.Scheduling.PageViewTrackingTest do
  @moduledoc """
  Integration tests for the `TymeslotWeb.Hooks.PageViewHook` on_mount hook.

  These tests exercise the full path: visiting a public scheduling URL
  triggers the LiveView mount, the hook spawns a supervised Task, and
  the Task calls `Tymeslot.Analytics.log_page_view/1` which writes to
  the database. We rely on shared sandbox ownership (async: false) so
  the spawned Task can see the test's DB connection.
  """
  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Hooks.PageViewHook

  @moduletag :scheduling
  @moduletag :live

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    RateLimiter.clear_all()
    Repo.delete_all(EventSchema)

    ctx = setup_public_meeting_type()
    %{ctx: ctx}
  end

  describe "page view logging on public scheduling pages" do
    test "logs a page view when the public scheduling page is mounted", %{conn: conn, ctx: ctx} do
      conn = put_req_header(conn, "user-agent", "Mozilla/5.0 (Macintosh) Chrome/126.0.0.0")

      {:ok, _view, _html} =
        live(conn, ~p"/#{ctx.username}/#{ctx.slug}?utm_source=linkedin&utm_medium=social")

      event = wait_for_event!()

      assert event.event_type == "booking_page_view"
      assert event.utm_source == "linkedin"
      assert event.utm_medium == "social"
      assert event.user_id == ctx.user.id
      assert event.meeting_type_id == ctx.meeting_type.id
      assert event.user_agent_family == "chrome"
      assert event.path == "/#{ctx.username}/#{ctx.slug}"
    end

    test "does not log a page view from a known bot user agent", %{conn: conn, ctx: ctx} do
      conn = put_req_header(conn, "user-agent", "Googlebot/2.1 (+http://www.google.com/bot.html)")

      {:ok, _view, _html} = live(conn, ~p"/#{ctx.username}/#{ctx.slug}")

      :ok = wait_quiet()
      assert Repo.aggregate(EventSchema, :count, :id) == 0
    end

    test "does not log on the static (non-connected) render", %{conn: conn, ctx: ctx} do
      conn = put_req_header(conn, "user-agent", "Mozilla/5.0 (Macintosh) Chrome/126.0.0.0")

      _resp = get(conn, ~p"/#{ctx.username}/#{ctx.slug}")

      :ok = wait_quiet()
      assert Repo.aggregate(EventSchema, :count, :id) == 0
    end
  end

  describe "resilient connect_info handling" do
    # Regression: under the deployed endpoint config, `connect_info`'s
    # `:x_headers` arrives as bare header-name strings rather than
    # `{name, value}` tuples. The hook used to pattern-match `{k, v}` and crash
    # the mount of every public scheduling page once analytics was enabled.
    test "mounts without crashing when x_headers are bare strings", %{ctx: ctx} do
      connect_info = %{
        x_headers: ["x-forwarded-for", "x-real-ip", "cf-connecting-ip", "origin"],
        peer_data: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil},
        user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/126.0.0.0 Safari/537.36"
      }

      base = %Phoenix.LiveView.Socket{transport_pid: self()}
      socket = Map.update!(base, :private, &Map.put(&1, :connect_info, connect_info))

      params = %{"username" => ctx.username, "slug" => ctx.slug}

      assert {:cont, %Phoenix.LiveView.Socket{} = result} =
               PageViewHook.on_mount(:default, params, %{}, socket)

      # The hash was still computed (from peer_data, since the string headers
      # yield no forwarded IP) and assigned for the booking flow to reuse.
      assert result.assigns.visitor_hash =~ ~r/^[0-9a-f]{64}$/
    end
  end

  defp setup_public_meeting_type do
    user = insert(:user)
    unique = System.unique_integer([:positive])

    profile =
      insert(:profile,
        user: user,
        username: "alice-#{unique}",
        timezone: "Europe/Berlin",
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Intro Call",
        duration_minutes: 30,
        is_active: true
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    slug = MeetingTypes.to_slug(meeting_type)

    %{
      user: user,
      profile: profile,
      username: profile.username,
      meeting_type: meeting_type,
      slug: slug
    }
  end

  # Polls the events table until an event is inserted by the supervised Task,
  # or fails the test after the timeout. Returns the inserted event.
  defp wait_for_event! do
    eventually(
      fn ->
        case Repo.all(EventSchema) do
          [event] -> event
          _other -> raise "expected exactly one event"
        end
      end,
      timeout: 2_000,
      interval: 50
    )
  end

  # Asserts that no analytics event is written within a short window.
  # Bot detection and the static-render guard both short-circuit before
  # any async work, so the poll simply confirms the table stays empty.
  defp wait_quiet do
    eventually(
      fn -> Repo.aggregate(EventSchema, :count, :id) == 0 end,
      timeout: 500,
      interval: 50
    )

    :ok
  end
end
