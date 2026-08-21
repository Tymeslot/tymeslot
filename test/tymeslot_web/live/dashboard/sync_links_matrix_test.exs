defmodule TymeslotWeb.Dashboard.SyncLinksMatrixTest do
  @moduledoc """
  The link grid: every ordered pair of the organiser's calendars as one matrix
  of three-state cells, staged as they are clicked and saved in a single
  submit.

  Storing the rows is not the feature — the grid reflecting them is. A cell
  that renders empty while its link exists sends the organiser to create
  something that already exists, so every assertion here reads the rendered
  cell rather than the database.

  The diagonal and the read-only columns are the two shapes the grid must
  refuse to offer. A self-link is rejected by a check constraint and an ICS
  subscription cannot receive a mirror at all; both must be visibly
  unavailable rather than failing on submit.
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
    insert(:calendar_integration,
      user: user,
      provider: provider,
      name: name,
      is_active: true
    )
  end

  defp cell_id(source, target), do: "sync-cell-#{source.id}-#{target.id}"

  defp cell(html, source, target) do
    html
    |> Floki.parse_document!()
    |> Floki.find("##{cell_id(source, target)}")
  end

  defp ticked?(html, source, target) do
    cell_state(html, cell_id(source, target)) == :active
  end

  defp disabled?(html, source, target) do
    html |> cell(source, target) |> Floki.attribute("disabled") != []
  end

  defp paused?(html, source, target) do
    cell_state(html, cell_id(source, target)) == :paused
  end

  # A cell is clicked to the state the test wants, then the grid is submitted.
  # This is the browser's own sequence: clicking stages, saving writes, and
  # nothing reaches a calendar in between. It replaces a helper that posted a
  # map of checkbox values — the grid has no inputs any more, and a payload
  # built by hand could assert a submission the UI cannot produce.
  defp save(view, states) do
    Enum.each(states, fn {cell, state} -> click_cell(view, cell, state) end)

    view
    |> element("#sync-link-matrix-form")
    |> render_submit(%{})
  end

  # Clicks the cell until it reads the wanted state, at most one full cycle.
  # The cycle is off -> active -> paused -> off, so three clicks return any
  # cell to where it started and a fourth would be a loop.
  defp click_cell(view, cell, wanted) do
    Enum.reduce_while(1..3, nil, fn _attempt, _acc ->
      if cell_state(render(view), cell) == wanted do
        {:halt, :ok}
      else
        {:cont, view |> element("##{cell}") |> render_click()}
      end
    end)
  end

  # A cell the grid never rendered cannot be clicked, so the forged-id path is
  # exercised by pushing the component's own event with the ids under test.
  defp push_cell(view, rendered_cell, source_id, target_id, state) do
    # Overridden params on a cell the grid *did* render: the event has to reach
    # the component that owns it, and a bare `render_click/3` on the view goes
    # to the parent LiveView, which has no such handler.
    view
    |> element("##{rendered_cell}")
    |> render_click(%{
      "source" => to_string(source_id),
      "target" => to_string(target_id),
      "state" => to_string(state)
    })

    view
    |> element("#sync-link-matrix-form")
    |> render_submit(%{})
  end

  # Read off the rendered class rather than an attribute: the state a cell is
  # in is exactly what it paints, and asserting on the paint is what catches a
  # grid that stores the right thing and shows the wrong one.
  defp cell_state(html, cell) do
    classes =
      html
      |> Floki.parse_document!()
      |> Floki.find("##{cell}")
      |> Floki.attribute("class")
      |> List.first()
      |> to_string()

    cond do
      String.contains?(classes, "border-turquoise-600") -> :active
      String.contains?(classes, "border-amber-300") -> :paused
      true -> :off
    end
  end

  defp pairs(user_id) do
    user_id
    |> SyncLink.list_links()
    |> MapSet.new(&{&1.source_integration_id, &1.target_integration_id})
  end

  describe "the grid" do
    test "offers a cell for every ordered pair but not the diagonal", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert cell(html, work, personal) != []
      assert cell(html, personal, work) != []

      # A calendar mirroring onto itself is refused by the database; offering
      # the cell would be offering a save that cannot succeed.
      assert cell(html, work, work) == []
      assert cell(html, personal, personal) == []
    end

    test "ticks the cells that are already linked", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert ticked?(html, work, personal)
      refute ticked?(html, personal, work)
    end

    test "disables a column whose calendar cannot receive a mirror", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      feed = calendar(user, "Holidays", "ics_url")

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # A subscription is read-only: a fine source, never a target.
      assert disabled?(html, work, feed)
      refute disabled?(html, feed, work)
    end
  end

  describe "saving the grid" do
    test "creates a link for each newly ticked cell", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html = save(view, [{cell_id(work, personal), :active}, {cell_id(personal, work), :active}])

      assert pairs(user.id) ==
               MapSet.new([{work.id, personal.id}, {personal.id, work.id}])

      assert ticked?(html, work, personal)
      assert ticked?(html, personal, work)
    end

    test "pauses a link on the click after the one that mirrors it", ctx do
      # The reversible stop. A cell clicked once past active keeps its link and
      # its settings, and writes nothing — which is what makes the grid safe to
      # click on, since the destructive stop is a further click away.
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html = save(view, [{cell_id(work, personal), :paused}])

      assert pairs(user.id) == MapSet.new([{work.id, personal.id}])
      assert [%{enabled: false}] = SyncLink.list_links(user.id)
      assert paused?(html, work, personal)
    end

    test "deletes a link on the click after the one that pauses it", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html = save(view, [{cell_id(work, personal), :off}])

      assert pairs(user.id) == MapSet.new()
      refute ticked?(html, work, personal)
      refute paused?(html, work, personal)
    end

    test "a cell the organiser never touched keeps its link", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")
      team = calendar(user, "Team")

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})
      [before] = SyncLink.list_links(user.id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      save(view, [{cell_id(work, personal), :active}, {cell_id(work, team), :active}])

      # Re-saving the existing cell must not have torn the link down and built
      # a new one: that would withdraw its placeholders from the provider.
      kept = Enum.find(SyncLink.list_links(user.id), &(&1.id == before.id))
      assert %{id: kept_id} = kept
      assert kept_id == before.id
      assert kept.inserted_at == before.inserted_at
    end

    test "ignores a cell naming a calendar the organiser does not own", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")
      stranger = insert(:calendar_integration, provider: "google", is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The cell is not on the page, so it cannot be clicked; pushing the
      # component's own event with the ids is the shape a forged one takes.
      push_cell(view, cell_id(work, personal), work.id, stranger.id, :active)

      assert pairs(user.id) == MapSet.new()
    end

    test "reports a rate-limited save rather than applying it", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      for _attempt <- 1..60, do: RateLimiter.check_sync_link_write_rate_limit(user.id)

      html = save(view, [{cell_id(work, personal), :active}])

      assert pairs(user.id) == MapSet.new()
      assert html =~ "reached the limit"
    end
  end

  describe "staging a change" do
    # The property the whole redesign rests on: a click edits the page, not a
    # calendar. Without it the grid is a set of twenty live buttons, each one
    # click from withdrawing placeholders.
    test "clicking a cell writes nothing until the grid is saved", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html = view |> element("##{cell_id(work, personal)}") |> render_click()

      assert SyncLink.list_links(user.id) == []
      assert cell_state(html, cell_id(work, personal)) == :active
    end

    test "counts the staged changes and offers to discard them", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      refute html =~ "change staged"

      html = view |> element("##{cell_id(work, personal)}") |> render_click()
      assert html =~ "1 change staged"

      html = view |> element("##{cell_id(personal, work)}") |> render_click()
      assert html =~ "2 changes staged"

      html = view |> element("button[phx-click='discard_sync_link_matrix']") |> render_click()

      refute html =~ "change staged"
      assert cell_state(html, cell_id(work, personal)) == :off
      assert SyncLink.list_links(user.id) == []
    end

    test "stops counting a cell clicked back to where it started", ctx do
      # Three clicks is a full cycle. A grid that counted clicks rather than
      # differences would report a pending change over a grid identical to the
      # stored one, and the organiser would save to apply nothing.
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html =
        Enum.reduce(1..3, nil, fn _click, _acc ->
          view |> element("##{cell_id(work, personal)}") |> render_click()
        end)

      refute html =~ "change staged"
      assert cell_state(html, cell_id(work, personal)) == :off
    end

    test "keeps the staged grid when the save is refused", ctx do
      # A refused save leaves the organiser's intent unapplied, so discarding
      # it would silently throw away the edit they were just told did not
      # happen.
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      view |> element("##{cell_id(work, personal)}") |> render_click()

      for _attempt <- 1..60, do: RateLimiter.check_sync_link_write_rate_limit(user.id)

      html = view |> element("#sync-link-matrix-form") |> render_submit(%{})

      assert SyncLink.list_links(user.id) == []
      assert html =~ "1 change staged"
      assert cell_state(html, cell_id(work, personal)) == :active
    end
  end
end
