defmodule TymeslotWeb.Dashboard.SyncLinksMatrixConfigTest do
  @moduledoc """
  Selecting a cell and configuring the link behind it.

  The grid answers *which* pairs mirror; it has no room for the five things a
  link can be configured with. Clicking a ticked cell selects that link and
  opens its settings beneath the grid, so ticking creates with defaults and
  clicking refines — two actions on one surface rather than a separate form
  that duplicates the grid's job.

  Read alongside `SyncLinksMatrixTest`, which covers the grid itself.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :utils

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user
  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp calendar(user, name) do
    insert(:calendar_integration, user: user, provider: "google", name: name, is_active: true)
  end

  # The settings used to open from a dot inside the grid; they now live in the
  # link's own card, expanded from its row. Same intent — "show me this link's
  # settings" — through the control that replaced it.
  defp select_cell(view, link) do
    view
    |> element("#sync-link-toggle-#{link.id}")
    |> render_click()
  end

  defp linked_pair(user) do
    work = calendar(user, "Work")
    personal = calendar(user, "Personal")
    {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})
    [link] = SyncLink.list_links(user.id)
    {work, personal, link}
  end

  describe "selecting a cell" do
    test "opens the settings for that link and names the pair", ctx do
      %{conn: conn, user: user} = ctx
      {_work, _personal, link} = linked_pair(user)

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # Nothing is selected until a cell is clicked, so the panel is absent.
      refute html =~ "sync-link-settings"

      html = select_cell(view, link)

      assert html =~ "sync-link-settings"
      # The panel has to say which pair it is editing, or a grid of similar
      # labels leaves the organiser editing whichever one they last clicked.
      assert html =~ "Work"
      assert html =~ "Personal"
    end

    test "offers the link's stored settings rather than blank defaults", ctx do
      %{conn: conn, user: user} = ctx
      {_work, _personal, link} = linked_pair(user)

      {:ok, _updated} =
        SyncLink.update_link(user.id, link.id, %{
          "privacy_tier" => "generic_label",
          "generic_label" => "Reserved"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html = select_cell(view, link)

      assert html =~ "Reserved"
    end

    test "an unticked cell is not selectable", ctx do
      %{conn: conn, user: user} = ctx
      work = calendar(user, "Work")
      personal = calendar(user, "Personal")

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # A card exists only where a link does, so an unlinked pair offers
      # nothing to configure.
      refute html =~ ~s(phx-click="toggle_sync_link_card")
      assert work.id != personal.id
    end
  end

  describe "saving the settings" do
    test "stores the tier and shows it back", ctx do
      %{conn: conn, user: user} = ctx
      {_work, _personal, link} = linked_pair(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      select_cell(view, link)

      html =
        view
        |> element("#sync-link-settings-#{link.id}")
        |> render_submit(%{
          "sync_link" => %{
            "id" => to_string(link.id),
            "privacy_tier" => "generic_label",
            "generic_label" => "Held"
          }
        })

      {:ok, saved} = CalendarSyncLinkQueries.get(link.id)
      assert saved.privacy_tier == "generic_label"
      assert saved.generic_label == "Held"

      # Storing it is not the feature; the panel reflecting it is.
      assert html =~ "Held"
    end

    test "keeps the panel on the link it was editing", ctx do
      %{conn: conn, user: user} = ctx
      {_work, _personal, link} = linked_pair(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      select_cell(view, link)

      html =
        view
        |> element("#sync-link-settings-#{link.id}")
        |> render_submit(%{
          "sync_link" => %{"id" => to_string(link.id), "privacy_tier" => "busy_only"}
        })

      # A save that closed the panel would make a second change to the same
      # link a fresh hunt for its cell.
      assert html =~ "sync-link-settings"
    end

    test "reports a re-point the provider refused rather than dropping the socket", ctx do
      %{conn: conn, user: user} = ctx
      {_work, personal, link} = linked_pair(user)
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      # Moving the link's calendar withdraws the placeholders from the old one
      # first, and this provider refuses. `update_link/3` then answers the
      # provider's own reason — neither a changeset nor `:not_found` — which
      # the save had no clause for, so the panel died with "Connection Lost"
      # instead of saying the save had not landed.
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      select_cell(view, link)

      html =
        view
        |> element("#sync-link-settings-#{link.id}")
        |> render_submit(%{
          "sync_link" => %{
            "privacy_tier" => "busy_only",
            "target_calendar_id" => "moved-to@group.calendar.google.com"
          }
        })

      assert html =~ "sync-link-settings"
      assert html =~ "could not be linked"

      {:ok, unmoved} = CalendarSyncLinkQueries.get(link.id)
      assert is_nil(unmoved.target_calendar_id)
      assert unmoved.target_integration_id == personal.id
    end

    test "refuses a link the organiser does not own", ctx do
      %{conn: conn, user: user} = ctx
      {_work, _personal, link} = linked_pair(user)

      other = insert(:user)

      other_source =
        insert(:calendar_integration, user: other, provider: "google", is_active: true)

      other_target =
        insert(:calendar_integration, user: other, provider: "google", is_active: true)

      {:ok, _summary} =
        SyncLink.apply_matrix(other.id, %{{other_source.id, other_target.id} => :active})

      [stranger_link] = SyncLink.list_links(other.id)

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The stranger's link is not in this organiser's grid, so no cell offers
      # its id — the only way to name it is to forge it.
      refute html =~ ~s(phx-value-id="#{stranger_link.id}")

      # Selecting this organiser's own link, then saving, must write to that
      # link and never to the one named by a forged id.
      select_cell(view, link)

      view
      |> element("#sync-link-settings-#{link.id}")
      |> render_submit(%{
        "sync_link" => %{"id" => to_string(link.id), "privacy_tier" => "full_passthrough"}
      })

      {:ok, untouched} =
        CalendarSyncLinkQueries.get(stranger_link.id)

      {:ok, own} = CalendarSyncLinkQueries.get(link.id)

      assert untouched.privacy_tier == "busy_only"
      assert own.privacy_tier == "full_passthrough"
    end
  end

  describe "the superseded form" do
    test "no longer offers a separate add-a-link form", ctx do
      %{conn: conn, user: user} = ctx
      _work = calendar(user, "Work")
      _personal = calendar(user, "Personal")

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The grid creates links now. Keeping a second way to do it invites the
      # organiser to use a form that says less than the grid above it.
      refute html =~ "sync-link-form"
      refute html =~ "Add a link"
    end
  end
end
