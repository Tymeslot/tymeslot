defmodule TymeslotWeb.Live.Scheduling.BookingPageLoadOnceTest do
  @moduledoc """
  A booking page's URL is settled once per mount (`PageAddress`), and what
  it settled is what the rest of the mount works from: the theme, and the
  organiser context the flow renders. So the profile and the page are each
  looked up once for the static render and once for the connected mount;
  the static request's response headers (`SecurityHeadersPlug`) look the
  profile up once more, before any LiveView runs.

  Counted at the query itself, the lookups that name the username or the
  page's slug, in whichever process makes them. Page-view analytics is off:
  in production it records the view from a background task, off the mount.
  """
  # The query handler is global, so a concurrent test would add its own reads.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    analytics = Application.get_env(:tymeslot, :booking_analytics_enabled)
    Application.put_env(:tymeslot, :booking_analytics_enabled, false)
    on_exit(fn -> Application.put_env(:tymeslot, :booking_analytics_enabled, analytics) end)

    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "1")
    page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "ISO consulting")
    type = insert(:meeting_type, user: user, name: "ISO audit")
    :ok = BookingPages.set_meeting_type(page, type.id, true)
    insert(:calendar_integration, user: user, is_active: true)

    parent = self()
    ref = make_ref()
    handler_id = "booking-page-load-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source, params: params}, _config ->
        cond do
          source == "profiles" and "joern" in params ->
            send(parent, {:load, ref, :profile})

          source == "booking_pages" and "einfachiso" in params ->
            send(parent, {:load, ref, :page})

          true ->
            :ok
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{ref: ref}
  end

  test "a page's start page looks its profile and page up once per mount", %{
    conn: conn,
    ref: ref
  } do
    {:ok, _view, html} = live(conn, ~p"/joern/einfachiso")

    # The page rendered as the page, not as the profile's own start page.
    assert html =~ "ISO consulting"
    assert loads(ref) == %{profile: 3, page: 2}
  end

  test "the username's own page looks its profile up once per mount", %{conn: conn, ref: ref} do
    {:ok, _view, html} = live(conn, ~p"/joern")

    assert html =~ "ISO audit"
    refute html =~ "ISO consulting"
    assert loads(ref) == %{profile: 3}
  end

  defp loads(ref) do
    Stream.repeatedly(fn ->
      receive do
        {:load, ^ref, kind} -> kind
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.frequencies()
  end
end
