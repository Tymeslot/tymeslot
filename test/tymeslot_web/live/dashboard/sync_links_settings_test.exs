defmodule TymeslotWeb.Dashboard.SyncLinksSettingsTest do
  @moduledoc """
  The sync-links tab in the Integrations Hub, exercised through the real hub
  route rather than the component in isolation.

  The first test here is the regression guard the wiring needs: a tab id
  missing from `parse_tab/2`'s allowlist does not error, it silently renders
  Calendars. Asserting the tab renders `data-tab-panel="sync_links"` — and that
  the Calendars panel is *not* what came back — is the only thing that catches
  it. Storing a link is likewise not the feature: the panel showing it is, so
  every write assertion here reads the rendered output.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    # The bucket is process-independent and leaks between tests; the write
    # paths below all pass through it.
    RateLimiter.clear_all()
    :ok
  end

  defp google(user, name, calendars \\ []) do
    insert(:calendar_integration,
      user: user,
      provider: "google",
      name: name,
      is_active: true,
      calendar_list: calendars
    )
  end

  describe "tab wiring" do
    test "renders its own panel rather than falling back to Calendars", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert html =~ ~s(data-tab-panel="sync_links")
      refute html =~ ~s(data-tab-panel="calendars")
    end

    test "offers the tab in the hub navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations")

      assert html =~ ~s(href="/dashboard/integrations?tab=sync_links")
    end

    test "carries a section header", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert html =~ "Calendar sync"
    end
  end

  describe "listing links" do
    test "prompts to connect a second calendar when there is only one", %{conn: conn, user: user} do
      google(user, "Only One")

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert html =~ "Connect a second calendar"
    end

    test "names both ends of every configured link", %{conn: conn, user: user} do
      source = google(user, "Work Google")
      target = google(user, "Personal Google")

      {:ok, _link} =
        SyncLink.create_link(user.id, %{
          "source_integration_id" => source.id,
          "target_integration_id" => target.id
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert html =~ "Work Google"
      assert html =~ "Personal Google"
    end
  end

  describe "creating a link through the form" do
    setup %{user: user} do
      source = google(user, "Work Google")

      target =
        google(user, "Personal Google", [
          %{"id" => "personal@gmail.com", "name" => "Personal", "selected" => true}
        ])

      {:ok, source: source, target: target}
    end

    test "renders the new link and reaches no provider", ctx do
      %{conn: conn, user: user, source: source, target: target} = ctx

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      refute has_element?(view, "#sync-link-form ~ * li[id^='sync-link-']")

      # Choosing the target is what reveals its calendars, so the form is
      # driven the way a browser drives it: change, then submit.
      view
      |> form("#sync-link-form", %{
        "sync_link" => %{
          "source_integration_id" => to_string(source.id),
          "target_integration_id" => to_string(target.id)
        }
      })
      |> render_change()

      html =
        view
        |> form("#sync-link-form", %{
          "sync_link" => %{
            "source_integration_id" => to_string(source.id),
            "target_integration_id" => to_string(target.id),
            "target_calendar_id" => "personal@gmail.com"
          }
        })
        |> render_submit()

      # The panel repaints with the stored link, naming both ends.
      assert html =~ "Work Google"
      assert html =~ "Personal Google"

      assert [link] = SyncLink.list_links(user.id)
      assert link.source_integration_id == source.id
      assert link.target_integration_id == target.id
      assert link.target_calendar_id == "personal@gmail.com"

      # Nothing was written to a calendar: mirroring is the engine's job, on
      # its own schedule, and configuring a link must not touch a provider. No
      # mirror row exists, so no placeholder was ever created.
      assert Repo.aggregate(CalendarSyncMirrorSchema, :count) == 0
    end

    test "refuses a link onto a read-only subscription, however the id arrives", ctx do
      %{conn: conn, user: user, source: source} = ctx

      ics =
        insert(:calendar_integration,
          user: user,
          provider: "ics_url",
          name: "Team Feed",
          is_active: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The picker never offers it, so this id can only arrive forged: pushed
      # at the component's own event rather than chosen in the form.
      html =
        view
        |> element("#sync-link-form")
        |> render_submit(%{
          "sync_link" => %{
            "source_integration_id" => to_string(source.id),
            "target_integration_id" => to_string(ics.id)
          }
        })

      assert html =~ "read-only subscription"
      assert SyncLink.list_links(user.id) == []
    end

    test "never offers a read-only subscription as a target", ctx do
      %{conn: conn, user: user} = ctx

      ics =
        insert(:calendar_integration,
          user: user,
          provider: "ics_url",
          name: "Team Feed",
          is_active: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # A source it may be — reading a feed is the one thing every provider can
      # do — but never a target.
      assert has_element?(view, "#sync-link-source option[value='#{ics.id}']")
      refute has_element?(view, "#sync-link-target option[value='#{ics.id}']")
    end
  end

  describe "the target calendar picker" do
    test "is offered once the chosen target honours a calendar id", %{conn: conn, user: user} do
      source = google(user, "Work Google")

      target =
        google(user, "Personal Google", [
          %{"id" => "personal@gmail.com", "name" => "Personal", "selected" => true}
        ])

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # Nothing to pick from until a target is named.
      refute html =~ ~s(name="sync_link[target_calendar_id]")

      html =
        view
        |> form("#sync-link-form", %{
          "sync_link" => %{
            "source_integration_id" => to_string(source.id),
            "target_integration_id" => to_string(target.id)
          }
        })
        |> render_change()

      assert html =~ ~s(name="sync_link[target_calendar_id]")
      assert html =~ "Personal"
    end

    test "is hidden once the chosen target is CalDAV, which ignores it", %{
      conn: conn,
      user: user
    } do
      source = google(user, "Work Google")

      caldav =
        insert(:calendar_integration,
          user: user,
          provider: "nextcloud",
          name: "Home Nextcloud",
          is_active: true,
          calendar_list: [%{"id" => "home", "name" => "Home", "selected" => true}]
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html =
        view
        |> form("#sync-link-form", %{
          "sync_link" => %{
            "source_integration_id" => to_string(source.id),
            "target_integration_id" => to_string(caldav.id)
          }
        })
        |> render_change()

      # `caldav_based?/1` is atom-only and answers false for the DB string, so
      # a picker gated on it would stay visible here and record a choice the
      # provider cannot honour.
      refute html =~ ~s(name="sync_link[target_calendar_id]")
      assert html =~ "primary calendar"
    end
  end

  describe "editing a link" do
    setup %{user: user} do
      source = google(user, "Work Google")
      target = google(user, "Personal Google")

      {:ok, link} =
        SyncLink.create_link(user.id, %{
          "source_integration_id" => source.id,
          "target_integration_id" => target.id
        })

      {:ok, link: link}
    end

    test "pauses a link and repaints it as paused", %{conn: conn, user: user, link: link} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html =
        view
        |> element("button[phx-click='toggle_sync_link'][phx-value-id='#{link.id}']")
        |> render_click()

      assert html =~ "Paused"
      assert [%{enabled: false}] = SyncLink.list_links(user.id)
    end

    test "deletes a link and drops it from the panel", %{conn: conn, user: user, link: link} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert has_element?(view, "#sync-link-#{link.id}")

      view
      |> element("button[phx-click='delete_sync_link'][phx-value-id='#{link.id}']")
      |> render_click()

      # The row is gone from the panel; the two calendars themselves are not,
      # so they must still be offered by the form.
      refute has_element?(view, "#sync-link-#{link.id}")
      assert has_element?(view, "#sync-link-target option", "Personal Google")
      assert SyncLink.list_links(user.id) == []
    end

    test "leaves another organiser's link alone", %{conn: conn, user: user} do
      stranger = insert(:user)
      stranger_source = insert(:calendar_integration, user: stranger, provider: "google")
      stranger_target = insert(:calendar_integration, user: stranger, provider: "google")

      {:ok, theirs} =
        SyncLink.create_link(stranger.id, %{
          "source_integration_id" => stranger_source.id,
          "target_integration_id" => stranger_target.id
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The id is never rendered for this user, so a click cannot produce it.
      # Overriding the params on their own link's button is the shape a forged
      # event takes: the component's handler, someone else's id.
      view
      |> element("button[phx-click='delete_sync_link']")
      |> render_click(%{"id" => to_string(theirs.id)})

      assert [_still_there] = SyncLink.list_links(stranger.id)
      assert length(SyncLink.list_links(user.id)) == 1
    end
  end
end
