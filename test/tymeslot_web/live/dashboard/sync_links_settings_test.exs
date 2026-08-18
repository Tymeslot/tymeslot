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

  Creating a link is covered by `SyncLinksGridCreationTest`, split out to keep
  this module under the line limit the analyser enforces. What remains here is
  what happens to a link once it exists: the settings panel behind a selected
  cell, pausing, deleting and the conflict log.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :utils

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
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

  # An integration reconnected as a published feed keeps its row and its id, so
  # every link already pointing at it goes on doing so. `create_link/2` would
  # have refused an ICS target outright, so the only way to reach this state is
  # the way production reaches it: the provider changes underneath a link that
  # already exists.
  defp reconnect_as_subscription(integration_id) do
    {1, _no_returning} =
      Repo.update_all(
        from(i in CalendarIntegrationSchema, where: i.id == ^integration_id),
        set: [provider: "ics_url"]
      )
  end

  # The dot under a ticked cell is what opens that link's settings; there is no
  # standalone form any more, so every per-link assertion starts here.
  defp select_cell(view, link) do
    view
    |> element(~s([phx-click="select_sync_cell"][phx-value-id="#{link.id}"]))
    |> render_click()
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

  describe "the generic-label tier" do
    setup %{user: user} do
      source = google(user, "Work Google")
      target = google(user, "Personal Google")

      # Created straight through the context rather than by ticking the cell:
      # grid creation has its own module, and what is under test here is the
      # settings panel that opens once a link exists.
      {:ok, _summary} = SyncLink.apply_matrix(user.id, [{source.id, target.id}])
      [link] = SyncLink.list_links(user.id)

      {:ok, source: source, target: target, link: link}
    end

    defp choose_tier(view, tier, extra \\ %{}) do
      params = Map.merge(%{"privacy_tier" => tier}, extra)

      view
      |> element("#sync-link-settings-form")
      |> render_change(%{"sync_link" => params})
    end

    test "offers a label input only once that tier is chosen", ctx do
      %{conn: conn, link: link} = ctx

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html = select_cell(view, link)

      # The default tier writes an opaque placeholder, which has no label to
      # ask for.
      refute html =~ ~s(name="sync_link[generic_label]")

      html = choose_tier(view, "busy_only")
      refute html =~ ~s(name="sync_link[generic_label]")

      html = choose_tier(view, "generic_label")
      assert html =~ ~s(name="sync_link[generic_label]")

      # Nor for the tier that copies the source's own title.
      html = choose_tier(view, "full_passthrough")
      refute html =~ ~s(name="sync_link[generic_label]")
    end

    test "carries the typed label all the way onto the placeholder", ctx do
      %{conn: conn, user: user, link: link} = ctx

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      select_cell(view, link)
      choose_tier(view, "generic_label")

      html =
        view
        |> element("#sync-link-settings-form")
        |> render_submit(%{
          "sync_link" => %{
            "privacy_tier" => "generic_label",
            "generic_label" => "Personal commitment"
          }
        })

      assert [saved] = SyncLink.list_links(user.id)
      assert saved.privacy_tier == "generic_label"
      assert saved.generic_label == "Personal commitment"

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

      payload = MirrorPayload.build(source_event, "target-uid", saved)
      assert payload.summary == "Personal commitment"

      # And the panel says so rather than describing a tier it did not store.
      assert html =~ "Personal commitment"
    end

    # The payload degrades a blank label to "Busy". That is the right last line
    # for a row written before this input existed, but it is the wrong answer
    # for a settings form: the panel would go on saying "Shown with a generic
    # label" over a placeholder that reads "Busy", which is the same false
    # claim the tier shipped with. So the form refuses instead of quietly
    # degrading, and the link keeps the tier it already had.
    test "refuses to store that tier without a label", ctx do
      %{conn: conn, user: user, link: link} = ctx

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      select_cell(view, link)
      choose_tier(view, "generic_label")

      html =
        view
        |> element("#sync-link-settings-form")
        |> render_submit(%{
          "sync_link" => %{"privacy_tier" => "generic_label", "generic_label" => "   "}
        })

      assert [unchanged] = SyncLink.list_links(user.id)
      assert unchanged.privacy_tier == "busy_only"
      assert is_nil(unchanged.generic_label)
      assert html =~ "label"

      # The typed values survive the refusal, so the organiser fixes one field
      # rather than filling the form in again.
      assert html =~ ~s(name="sync_link[generic_label]")
    end

    test "leaves the other tiers free of that requirement", ctx do
      %{conn: conn, user: user, link: link} = ctx

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      select_cell(view, link)

      view
      |> element("#sync-link-settings-form")
      |> render_submit(%{"sync_link" => %{"privacy_tier" => "busy_only"}})

      assert [saved] = SyncLink.list_links(user.id)
      assert saved.privacy_tier == "busy_only"
      assert is_nil(saved.generic_label)
    end
  end

  describe "the target calendar picker" do
    test "is offered once the selected link's target honours a calendar id", ctx do
      %{conn: conn, user: user} = ctx
      source = google(user, "Work Google")

      target =
        google(user, "Personal Google", [
          %{"id" => "personal@gmail.com", "name" => "Personal", "selected" => true}
        ])

      {:ok, _summary} = SyncLink.apply_matrix(user.id, [{source.id, target.id}])
      [link] = SyncLink.list_links(user.id)

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # Nothing to pick from until a link is selected: the pair is what decides
      # whose calendars are on offer.
      refute html =~ ~s(name="sync_link[target_calendar_id]")

      html = select_cell(view, link)

      assert html =~ ~s(name="sync_link[target_calendar_id]")
      assert html =~ ~s(id="sync-link-settings-calendar")
      assert html =~ "Personal"
    end

    test "is hidden once the selected link's target is CalDAV, which ignores it", ctx do
      %{conn: conn, user: user} = ctx
      source = google(user, "Work Google")

      caldav =
        insert(:calendar_integration,
          user: user,
          provider: "nextcloud",
          name: "Home Nextcloud",
          is_active: true,
          calendar_list: [%{"id" => "home", "name" => "Home", "selected" => true}]
        )

      {:ok, _summary} = SyncLink.apply_matrix(user.id, [{source.id, caldav.id}])
      [link] = SyncLink.list_links(user.id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html = select_cell(view, link)

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

    # Both directions of the pause/resume asymmetry, read off the panel rather
    # than off the row. The button is the same button either way, so what
    # distinguishes the two cases is entirely what the page says afterwards.
    test "pauses a link whose target was reconnected as a subscription", %{
      conn: conn,
      user: user,
      link: link
    } do
      reconnect_as_subscription(link.target_integration_id)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html =
        view
        |> element("button[phx-click='toggle_sync_link'][phx-value-id='#{link.id}']")
        |> render_click()

      # The one control an organiser has over a link that can no longer write
      # anywhere has to keep working, or a broken link is unstoppable.
      assert html =~ "Paused"
      assert [%{enabled: false}] = SyncLink.list_links(user.id)
    end

    test "refuses to resume a link whose target was reconnected as a subscription", %{
      conn: conn,
      user: user,
      link: link
    } do
      {:ok, _paused} = SyncLink.toggle_enabled(user.id, link.id, false)
      reconnect_as_subscription(link.target_integration_id)

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      assert html =~ "Paused"

      html =
        view
        |> element("button[phx-click='toggle_sync_link'][phx-value-id='#{link.id}']")
        |> render_click()

      # Storing the row is not the feature: the panel still has to say the link
      # is paused, and still offer "Resume" rather than the "Pause" it would
      # render for a link it believed had come back.
      assert html =~ "Paused"
      assert html =~ "Resume"
      assert [%{enabled: false}] = SyncLink.list_links(user.id)
    end

    test "deletes a link and drops it from the panel", %{conn: conn, user: user, link: link} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert has_element?(view, "#sync-link-#{link.id}")

      view
      |> element("button[phx-click='delete_sync_link'][phx-value-id='#{link.id}']")
      |> render_click()

      # The row is gone from the panel; the two calendars themselves are not,
      # so the grid must still offer them — as a row to mirror from and as a
      # column to mirror onto — ready to be linked again.
      refute has_element?(view, "#sync-link-#{link.id}")

      assert has_element?(
               view,
               ~s(#sync-link-matrix-form tbody th[scope="row"]),
               "Personal Google"
             )

      assert has_element?(
               view,
               ~s(#sync-link-matrix-form thead th[scope="col"]),
               "Personal Google"
             )

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

    # The visibility half of the recurrence gate, asserted where it has to land.
    # A recurring source on a link that cannot carry a series is refused, and
    # the refusal used to be `{:discard, :not_an_eligible_source}` and nothing
    # else — an Oban outcome the organiser never sees. Their repeating meetings
    # went unmirrored, the slots stayed bookable, and the dashboard said
    # nothing.
    #
    # Recording the row is not the feature; the organiser reading the sentence
    # is. A conflict row nobody renders is exactly the failure this suite's
    # rule about rendered output was written for, so this asserts the painted
    # page rather than the stored row.
    test "warns that a repeating event is not being mirrored", %{conn: conn, link: link} do
      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "weekly-standup-uid",
        kind: "series_unsupported",
        resolution: "skipped",
        detail: %{
          "unsupported_end" => "source",
          "source_provider" => "outlook",
          "target_provider" => "google"
        }
      )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert has_element?(view, "#sync-link-conflicts-#{link.id}")

      # The two things an organiser has to be able to act on: that this is a
      # repeating event which is *not* being mirrored, and which event it is.
      assert html =~ "repeating event"
      assert html =~ "weekly-standup-uid"

      # And the consequence spelled out, because "not mirrored" alone reads as
      # a cosmetic gap rather than as time that can be double-booked.
      assert html =~ "booked over"

      # It must not fall through to the catch-all, which says only that the two
      # calendars differed — true of every kind and actionable for none.
      refute html =~ "The two calendars differed."
    end

    # The same sentence for the other end of the link, and the case an organiser
    # with an Outlook target actually hits. Microsoft Graph has no EXDATE
    # analogue — `patternedRecurrence` is `pattern` and `range` and nothing else
    # — so a series mirrored there would keep blocking occurrences the organiser
    # had cancelled. The link is refused instead, and this is the assertion that
    # the refusal is legible rather than merely recorded.
    #
    # Asserted separately from the source-side row above because the rendered
    # sentence is deliberately end-agnostic: a version that rendered only the
    # detail it recognised, or that named the failing provider, would pass the
    # test above and leave this one blank or wrong.
    test "warns for an unmirrorable series when the TARGET is the incapable end", ctx do
      %{conn: conn, link: link} = ctx

      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "outlook-target-standup-uid",
        kind: "series_unsupported",
        resolution: "skipped",
        detail: %{
          "unsupported_end" => "target",
          "source_provider" => "google",
          "target_provider" => "outlook"
        }
      )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      assert has_element?(view, "#sync-link-conflicts-#{link.id}")

      assert html =~ "repeating event"
      assert html =~ "outlook-target-standup-uid"
      assert html =~ "booked over"

      refute html =~ "The two calendars differed."
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
