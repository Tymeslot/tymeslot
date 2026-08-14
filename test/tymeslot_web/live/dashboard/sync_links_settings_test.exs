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

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload
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

    # The panel is translated; the changeset's messages have to be too, or a
    # non-English organiser reads an English sentence inside an otherwise
    # German page and cannot tell whether it came from Tymeslot or from their
    # calendar provider. Two halves fail independently: the schema must carry
    # an extracted msgid rather than a bare English literal, and the component
    # must route it through the "errors" domain instead of assigning it raw.
    test "refuses that link in the organiser's own language", ctx do
      %{conn: conn, user: user, source: source} = ctx

      # Set on the user rather than with `put_locale/2` in the test process:
      # the dashboard's `AppLocaleHook` resolves the locale itself on mount,
      # from the signed-in organiser's saved interface language, so this is the
      # path a German organiser actually arrives by.
      {:ok, user} = UserQueries.update_user_locale(user, "de")

      ics =
        insert(:calendar_integration,
          user: user,
          provider: "ics_url",
          name: "Team Feed",
          is_active: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html =
        view
        |> element("#sync-link-form")
        |> render_submit(%{
          "sync_link" => %{
            "source_integration_id" => to_string(source.id),
            "target_integration_id" => to_string(ics.id)
          }
        })

      # Asserted against the catalogue rather than a literal, so the assertion
      # cannot drift from the translation that ships. Looked up in an explicit
      # German scope: the locale the view resolved lives in the view's process,
      # not this one.
      translated =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          Gettext.dgettext(
            TymeslotWeb.Gettext,
            "errors",
            "is a read-only subscription and cannot receive mirrored events"
          )
        end)

      refute translated == "is a read-only subscription and cannot receive mirrored events",
             "the German catalogue has no translation for the read-only target message"

      assert html =~ translated
      refute html =~ "read-only subscription"
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

  describe "the generic-label tier" do
    setup %{user: user} do
      source = google(user, "Work Google")
      target = google(user, "Personal Google")

      {:ok, source: source, target: target}
    end

    defp choose_tier(view, source, target, tier, extra \\ %{}) do
      params =
        Map.merge(
          %{
            "source_integration_id" => to_string(source.id),
            "target_integration_id" => to_string(target.id),
            "privacy_tier" => tier
          },
          extra
        )

      form(view, "#sync-link-form", %{"sync_link" => params})
    end

    test "offers a label input only once that tier is chosen", ctx do
      %{conn: conn, source: source, target: target} = ctx

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The default tier writes an opaque placeholder, which has no label to
      # ask for.
      refute html =~ ~s(name="sync_link[generic_label]")

      html = view |> choose_tier(source, target, "busy_only") |> render_change()
      refute html =~ ~s(name="sync_link[generic_label]")

      html = view |> choose_tier(source, target, "generic_label") |> render_change()
      assert html =~ ~s(name="sync_link[generic_label]")

      # Nor for the tier that copies the source's own title.
      html = view |> choose_tier(source, target, "full_passthrough") |> render_change()
      refute html =~ ~s(name="sync_link[generic_label]")
    end

    test "carries the typed label all the way onto the placeholder", ctx do
      %{conn: conn, user: user, source: source, target: target} = ctx

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      view |> choose_tier(source, target, "generic_label") |> render_change()

      html =
        view
        |> choose_tier(source, target, "generic_label", %{
          "generic_label" => "Personal commitment"
        })
        |> render_submit()

      assert [link] = SyncLink.list_links(user.id)
      assert link.privacy_tier == "generic_label"
      assert link.generic_label == "Personal commitment"

      # Storing the label is not the feature: the placeholder carrying it is.
      # The payload is what a tool reading the target calendar actually sees,
      # and before this was wired it read "Busy" while the panel claimed a
      # generic label.
      source_event = %{
        summary: "Board meeting",
        start_at: ~U[2026-03-02 09:00:00Z],
        end_at: ~U[2026-03-02 10:00:00Z],
        all_day: false
      }

      payload = MirrorPayload.build(source_event, "target-uid", link)
      assert payload.summary == "Personal commitment"

      # And the panel says so rather than describing a tier it did not store.
      assert html =~ "Personal commitment"
    end

    # The payload degrades a blank label to "Busy". That is the right last line
    # for a row written before this input existed, but it is the wrong answer
    # for a form: the panel would go on saying "Shown with a generic label"
    # over a placeholder that reads "Busy", which is the same false claim the
    # tier shipped with. So the form refuses instead of quietly degrading.
    test "refuses to store that tier without a label", ctx do
      %{conn: conn, user: user, source: source, target: target} = ctx

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      view |> choose_tier(source, target, "generic_label") |> render_change()

      html =
        view
        |> choose_tier(source, target, "generic_label", %{"generic_label" => "   "})
        |> render_submit()

      assert SyncLink.list_links(user.id) == []
      assert html =~ "label"

      # The typed values survive the refusal, so the organiser fixes one field
      # rather than filling the form in again.
      assert html =~ ~s(name="sync_link[generic_label]")
    end

    test "leaves the other tiers free of that requirement", ctx do
      %{conn: conn, user: user, source: source, target: target} = ctx

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      view |> choose_tier(source, target, "busy_only") |> render_submit()

      assert [link] = SyncLink.list_links(user.id)
      assert link.privacy_tier == "busy_only"
      assert is_nil(link.generic_label)
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

  describe "the conflict log" do
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

    test "says so when a link has resolved nothing", %{conn: conn, link: link} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # A link with a clean history must not render an empty panel that reads
      # as a missing feature.
      refute has_element?(view, "#sync-link-conflicts-#{link.id}")
    end

    test "names every resolution it has made for a link", %{conn: conn, link: link} do
      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "board-meeting-uid",
        kind: "mirror_edited",
        resolution: "source_won"
      )

      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "standup-uid",
        kind: "delete_race",
        resolution: "deletion_won"
      )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert has_element?(view, "#sync-link-conflicts-#{link.id}")

      # Storing the resolution is not the feature; telling the organiser what
      # happened to their event is. Both the plain-language reason and the event
      # it happened to have to reach the page.
      assert html =~ "edited on the target calendar"
      assert html =~ "board-meeting-uid"
      assert html =~ "deleted while the placeholder was edited"
      assert html =~ "standup-uid"
    end

    test "explains a write that never landed", %{conn: conn, link: link} do
      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "quarterly-review-uid",
        kind: "write_failed",
        resolution: "skipped",
        detail: %{"error" => "forbidden", "operation" => "update"}
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert html =~ "could not be written to the target calendar"
      assert html =~ "quarterly-review-uid"
    end

    test "never shows another organiser's history, however the id arrives", ctx do
      %{conn: conn, link: link} = ctx

      stranger = insert(:user)
      stranger_source = insert(:calendar_integration, user: stranger, provider: "google")
      stranger_target = insert(:calendar_integration, user: stranger, provider: "google")

      {:ok, theirs} =
        SyncLink.create_link(stranger.id, %{
          "source_integration_id" => stranger_source.id,
          "target_integration_id" => stranger_target.id
        })

      insert(:calendar_sync_conflict,
        sync_link_id: theirs.id,
        source_uid: "their-private-event-uid",
        kind: "mirror_edited"
      )

      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "my-own-event-uid",
        kind: "mirror_edited"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The history names event UIDs and the times two calendars diverged. The
      # stranger's link id is never rendered here, so it can only arrive forged
      # — pushed at the component's own event on their own link's control.
      html =
        view
        |> element("button[phx-click='show_sync_link_conflicts']")
        |> render_click(%{"id" => to_string(theirs.id)})

      refute html =~ "their-private-event-uid"
      assert render(view) =~ "my-own-event-uid"
    end
  end
end
