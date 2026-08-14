defmodule TymeslotWeb.Dashboard.SyncLinksMatrixTest do
  @moduledoc """
  The link grid: every ordered pair of the organiser's calendars as one
  checkbox matrix, saved in a single submit.

  Storing the rows is not the feature — the grid reflecting them is. A cell
  that renders unticked while its link exists sends the organiser to untick
  something that is already off, so every assertion here reads the rendered
  checkbox rather than the database.

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
    html |> cell(source, target) |> Floki.attribute("checked") != []
  end

  defp disabled?(html, source, target) do
    html |> cell(source, target) |> Floki.attribute("disabled") != []
  end

  # Every cell the grid offers is named explicitly — "true" for ticked, "false"
  # for cleared. `render_submit/2` merges over the form's rendered state rather
  # than replacing it, so omitting a cell leaves its rendered `checked` in the
  # payload and unticking would be untestable. Naming every cell mirrors what
  # the browser sends, because each checkbox is paired with a hidden "false".
  defp save(view, ticked) do
    ticked = MapSet.new(ticked)

    # Every cell the page offered, so a cleared one is named "false" rather
    # than merely omitted. Read off the rendered form so the payload matches
    # what a browser would send for this exact grid.
    payload =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find(~s(#sync-link-matrix-form input[type="checkbox"]))
      |> Enum.map(&(&1 |> Floki.attribute("id") |> List.first()))
      |> Enum.reject(&is_nil/1)
      |> Map.new(fn cell ->
        {cell, if(MapSet.member?(ticked, cell), do: "true", else: "false")}
      end)

    view
    |> element("#sync-link-matrix-form")
    |> render_submit(%{"matrix" => Map.merge(payload, forged(ticked, payload))})
  end

  # A test that submits a cell the grid never rendered is exercising the
  # forged-id path deliberately, so it is added rather than filtered away.
  defp forged(ticked, payload) do
    ticked
    |> Enum.reject(&Map.has_key?(payload, &1))
    |> Map.new(&{&1, "true"})
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

      {:ok, _summary} = SyncLink.apply_matrix(user.id, [{work.id, personal.id}])

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

      html = save(view, [cell_id(work, personal), cell_id(personal, work)])

      assert pairs(user.id) ==
               MapSet.new([{work.id, personal.id}, {personal.id, work.id}])

      assert ticked?(html, work, personal)
      assert ticked?(html, personal, work)
    end

    test "deletes a link for each cleared cell", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, _summary} = SyncLink.apply_matrix(user.id, [{work.id, personal.id}])

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html = save(view, [])

      assert pairs(user.id) == MapSet.new()
      refute ticked?(html, work, personal)
    end

    test "a cell the organiser never touched keeps its link", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")
      team = calendar(user, "Team")

      {:ok, _summary} = SyncLink.apply_matrix(user.id, [{work.id, personal.id}])
      [before] = SyncLink.list_links(user.id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      save(view, [cell_id(work, personal), cell_id(work, team)])

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
      _personal = calendar(user, "Personal")
      stranger = insert(:calendar_integration, provider: "google", is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The cell is not on the page; submitting it anyway is a forged id.
      save(view, ["sync-cell-#{work.id}-#{stranger.id}"])

      assert pairs(user.id) == MapSet.new()
    end

    test "reports a rate-limited save rather than applying it", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      for _attempt <- 1..60, do: RateLimiter.check_sync_link_write_rate_limit(user.id)

      html = save(view, [cell_id(work, personal)])

      assert pairs(user.id) == MapSet.new()
      assert html =~ "reached the limit"
    end
  end
end
