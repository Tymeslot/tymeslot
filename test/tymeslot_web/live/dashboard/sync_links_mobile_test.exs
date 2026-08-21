defmodule TymeslotWeb.Dashboard.SyncLinksMobileTest do
  @moduledoc """
  The layout a phone gets: the per-calendar accordion that replaces the matrix
  below `sm:`, and the guarantee that it and the grid stay one feature.

  The bug that produced it was not cosmetic. The tab bar was a plain `flex`
  with no wrapping, so at 375px its four tabs needed 463px and the last two —
  "Calendar sync" and "Payments" — were painted past an edge that could not be
  scrolled. They were unreachable, which to an organiser is indistinguishable
  from the feature not existing. The grid behind the tab had its own version of
  the same problem: it scrolled, but a 150px row header plus 132px columns
  shows one column at a time, so the header naming the row scrolled away with
  the cell being configured.

  ## What these tests can and cannot check

  A test has no viewport, so none of this asserts a pixel. What it asserts is
  that both layouts are rendered, that each is hidden at the breakpoint where
  the other takes over, and — the load-bearing part — that they drive the
  *same* model: the same `cycle_sync_cell` event, the same staging, the same
  save. Two layouts with two models would drift, and the drift would surface as
  an organiser rotating their phone and being told something different about
  which calendars are mirroring.

  So the interesting assertions here are the ones that stage a change through
  the accordion and read it back off the grid.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp calendar(user, name, provider \\ "google") do
    insert(:calendar_integration, user: user, provider: provider, name: name, is_active: true)
  end

  defp open_source(view, source) do
    view |> element("#sync-source-toggle-#{source.id}") |> render_click()
  end

  defp tap(view, source, target, state) do
    view |> element("#sync-seg-#{source.id}-#{target.id}-#{state}") |> render_click()
  end

  defp cell_state(html, source, target) do
    classes =
      html
      |> Floki.parse_document!()
      |> Floki.find("#sync-cell-#{source.id}-#{target.id}")
      |> Floki.attribute("class")
      |> List.first()
      |> to_string()

    cond do
      String.contains?(classes, "border-turquoise-600") -> :active
      String.contains?(classes, "border-amber-300") -> :paused
      true -> :off
    end
  end

  defp segment_pressed?(html, source, target, state) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#sync-seg-#{source.id}-#{target.id}-#{state}")
    |> Floki.attribute("aria-pressed")
    |> List.first() == "true"
  end

  describe "the mobile layout" do
    test "renders the accordion and the grid, each hidden where the other serves", ctx do
      %{conn: conn, user: user} = ctx
      calendar(user, "Work")
      calendar(user, "Personal")

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # Both are in the DOM; CSS decides which is painted, so a test can only
      # check that each carries the class that hides it at the other's size.
      assert has_element?(view, "[id^='sync-source-']")
      assert has_element?(view, "#sync-link-matrix-form table")

      assert html =~ "sm:hidden"
      assert html =~ "hidden overflow-x-auto pb-2 sm:block"
    end

    test "lists every calendar as a source, in the order the grid uses", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")
      feed = calendar(user, "Team Feed", "ics_url")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # A subscription can send even though it cannot receive, so it is a
      # source section like any other — the asymmetry belongs to the targets.
      for source <- [work, personal, feed] do
        assert has_element?(view, "#sync-source-#{source.id}")
      end
    end

    test "offers no control for a target that cannot receive", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      feed = calendar(user, "Team Feed", "ics_url")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      html = open_source(view, work)

      # Three segments that would all be refused teach the organiser nothing;
      # the row says why instead.
      refute has_element?(view, "#sync-seg-#{work.id}-#{feed.id}-active")
      assert html =~ "can send, but cannot receive"
    end

    test "does not offer a calendar as its own target", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      open_source(view, work)

      refute has_element?(view, "#sync-seg-#{work.id}-#{work.id}-active")
    end
  end

  describe "staging through the accordion" do
    test "a tap stages the state it names and writes nothing", ctx do
      # The segment sends its own state rather than "the next one", so one tap
      # reaches any state — the difference from the grid's cycling cell, and
      # the reason a phone does not need three taps to pause something.
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      open_source(view, work)

      html = tap(view, work, personal, "paused")

      assert SyncLink.list_links(user.id) == []
      assert segment_pressed?(html, work, personal, "paused")
      assert html =~ "1 change staged"
    end

    test "a change staged on the accordion shows on the grid", ctx do
      # The assertion that keeps the two layouts one feature. Both read the
      # same staging map, so a tap on the phone layout has to paint the desktop
      # cell — if it does not, the two have separate models and will disagree.
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      open_source(view, work)

      html = tap(view, work, personal, "active")

      assert cell_state(html, work, personal) == :active
    end

    test "saving applies what the accordion staged", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      open_source(view, work)
      tap(view, work, personal, "active")

      view |> element("#sync-link-matrix-form") |> render_submit(%{})

      assert [link] = SyncLink.list_links(user.id)
      assert link.source_integration_id == work.id
      assert link.target_integration_id == personal.id
      assert link.enabled
    end

    test "tapping the state a pair is already in stages nothing", ctx do
      # The count reports differences, not taps. A segment showing the stored
      # state is not an edit, and reporting one would send the organiser to
      # save a grid identical to what is stored.
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      open_source(view, work)

      html = tap(view, work, personal, "active")

      refute html =~ "change staged"
    end

    test "pausing through the accordion keeps the link", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      open_source(view, work)
      tap(view, work, personal, "paused")

      view |> element("#sync-link-matrix-form") |> render_submit(%{})

      assert [%{enabled: false}] = SyncLink.list_links(user.id)
    end
  end

  describe "the section header" do
    test "counts what the calendar is doing, including a staged change", ctx do
      # Read off the effective state rather than the stored one: a header that
      # lagged the taps would tell the organiser their change had not landed.
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      assert html =~ "None"

      open_source(view, work)
      html = tap(view, work, personal, "active")

      assert html =~ "1 mirroring"
    end

    test "names mirroring and paused separately", ctx do
      # One number would report a paused link as active work, which is the one
      # thing the pause state exists to distinguish.
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")
      team = calendar(user, "Team")

      {:ok, _summary} =
        SyncLink.apply_matrix(user.id, %{
          {work.id, personal.id} => :active,
          {work.id, team.id} => :paused
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert html =~ "1 mirroring"
      assert html =~ "1 paused"
    end
  end
end
