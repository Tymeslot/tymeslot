defmodule TymeslotWeb.Dashboard.SyncLinksConflictLogTest do
  @moduledoc """
  What the panel tells an organiser about the divergences mirroring resolved on
  its own, and how they clear that list once they have read it.

  Split from `SyncLinksSettingsTest` when that module passed the line budget
  the analyser enforces. The seam is a real one: everything here is about the
  conflict audit — the count above the grid, the collapsed log inside a card,
  and the dismissal that resets both — and none of it touches the tier, the
  label or the target calendar those tests cover.

  The rule the whole file exists to protect: a resolution the organiser never
  sees is indistinguishable from a bug. Mirroring overwrites an edited
  placeholder and withdraws one whose source was deleted, both silently and
  both correctly, so the record of having done so is the only thing standing
  between a working feature and a support ticket.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Integrations.Calendar.SyncLink.ConflictHistory
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

  # A link's settings live in its own card, expanded from its row. There is no
  # standalone form and no selection dot any more, so every per-link assertion
  # starts by opening the card.
  defp select_cell(view, link) do
    view
    |> element("#sync-link-toggle-#{link.id}")
    |> render_click()
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
      select_cell(view, link)

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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The log lives inside the link's card, so it is opened first.
      html = select_cell(view, link)

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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      html = select_cell(view, link)

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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The log lives inside the link's card, so it is opened first.
      html = select_cell(view, link)

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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The log lives inside the link's card, so it is opened first.
      html = select_cell(view, link)

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
      select_cell(view, link)

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

  describe "clearing the conflict log" do
    setup %{user: user} do
      source = insert(:calendar_integration, user: user, provider: "google", is_active: true)
      target = insert(:calendar_integration, user: user, provider: "google", is_active: true)

      {:ok, link} =
        SyncLink.create_link(user.id, %{
          "source_integration_id" => source.id,
          "target_integration_id" => target.id
        })

      for uid <- ~w(first-uid second-uid) do
        insert(:calendar_sync_conflict,
          sync_link_id: link.id,
          source_uid: uid,
          kind: "mirror_edited",
          resolution: "source_won"
        )
      end

      {:ok, link: link}
    end

    test "counts the unseen resolutions above the grid", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The count is the only way an organiser learns that mirroring
      # overwrote something, so it has to be visible without opening a card.
      assert html =~ "2 differences resolved automatically"
    end

    test "marking a link's log as seen clears its count", %{conn: conn, user: user, link: link} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      select_cell(view, link)

      html =
        view
        |> element("button[phx-click='dismiss_sync_link_conflicts'][phx-value-id='#{link.id}']")
        |> render_click()

      # Cleared for the reader, kept for the record: the rows are still there
      # with a dismissal stamped on them, which is what answers "the warning
      # came back" later.
      refute html =~ "differences resolved automatically"
      assert Repo.aggregate(CalendarSyncConflictSchema, :count) == 2

      assert {:ok, []} = ConflictHistory.for_link(user.id, link.id)
    end

    test "marking everything as seen clears every link at once", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      html =
        view
        |> element("button[phx-click='dismiss_all_sync_link_conflicts']")
        |> render_click()

      refute html =~ "differences resolved automatically"
      assert ConflictHistory.recent_for_user(user.id) == %{}
    end

    test "leaves another organiser's log alone, however the id arrives", ctx do
      %{conn: conn, link: link} = ctx
      stranger = insert(:user)
      their_source = insert(:calendar_integration, user: stranger, provider: "google")
      their_target = insert(:calendar_integration, user: stranger, provider: "google")

      {:ok, theirs} =
        SyncLink.create_link(stranger.id, %{
          "source_integration_id" => their_source.id,
          "target_integration_id" => their_target.id
        })

      insert(:calendar_sync_conflict, sync_link_id: theirs.id, source_uid: "their-uid")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")
      select_cell(view, link)

      # Their id is never rendered here, so it can only arrive forged — pushed
      # at the component's own event through the organiser's own control.
      view
      |> element("button[phx-click='dismiss_sync_link_conflicts'][phx-value-id='#{link.id}']")
      |> render_click(%{"id" => to_string(theirs.id)})

      assert {:ok, [_still_unseen]} = ConflictHistory.for_link(stranger.id, theirs.id)
    end
  end
end
