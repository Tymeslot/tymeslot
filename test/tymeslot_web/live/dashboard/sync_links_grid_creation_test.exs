defmodule TymeslotWeb.Dashboard.SyncLinksGridCreationTest do
  @moduledoc """
  Creating a link by ticking a cell of the grid, and the things the grid must
  refuse to create.

  These were written against the "Add a link" form the panel used to carry.
  That form is gone — the grid creates links now — but what it was guarding is
  unchanged: a save must reach no provider, a read-only subscription must never
  become a target however its id arrives, and a refusal must be readable by an
  organiser who does not read English.

  Kept apart from `SyncLinksSettingsTest` because that module is already at the
  line limit the analyser enforces, and apart from `SyncLinksMatrixTest`
  because that one covers what the grid *draws* rather than what a save through
  it may and may not write.
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

  defp cell_id(source, target), do: "sync-cell-#{source.id}-#{target.id}"

  defp cell(html, source, target) do
    html
    |> Floki.parse_document!()
    |> Floki.find("##{cell_id(source, target)}")
  end

  defp disabled?(html, source, target) do
    html |> cell(source, target) |> Floki.attribute("disabled") != []
  end

  # Clicks one cell to mirroring and saves the grid — the browser's own
  # sequence, since the grid has no inputs to post.
  #
  # Every one of these tests starts from an empty grid and asserts on what a
  # single click did or did not create, so one click is all that is staged.
  # `SyncLinksMatrixTest` covers pausing and clearing, which need a cell
  # clicked more than once.
  defp save_cell(view, cell) do
    view |> element("##{cell}") |> render_click()

    view
    |> element("#sync-link-matrix-form")
    |> render_submit(%{})
  end

  # The same save for a pair the grid refuses to offer. A disabled cell cannot
  # be clicked, so the ids are pushed at the component's own event through a
  # cell it *did* draw — which is the shape a forged submission takes, and the
  # only way these two cases can reach the write path at all.
  defp save_forged_cell(view, rendered_cell, source, target) do
    view
    |> element("##{rendered_cell}")
    |> render_click(%{
      "source" => to_string(source.id),
      "target" => to_string(target.id),
      "state" => "active"
    })

    view
    |> element("#sync-link-matrix-form")
    |> render_submit(%{})
  end

  describe "creating a link through the grid" do
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

      refute has_element?(view, "li[id^='sync-link-']")

      html = save_cell(view, cell_id(source, target))

      # The panel repaints with the stored link, naming both ends.
      assert html =~ "Work Google"
      assert html =~ "Personal Google"

      assert [link] = SyncLink.list_links(user.id)
      assert link.source_integration_id == source.id
      assert link.target_integration_id == target.id

      # Nothing was written to a calendar: mirroring is the engine's job, on
      # its own schedule, and configuring a link must not touch a provider. No
      # mirror row exists, so no placeholder was ever created.
      assert Repo.aggregate(CalendarSyncMirrorSchema, :count) == 0
    end

    test "refuses a link onto a read-only subscription, however the id arrives", ctx do
      %{conn: conn, user: user, source: source, target: target} = ctx

      ics =
        insert(:calendar_integration,
          user: user,
          provider: "ics_url",
          name: "Team Feed",
          is_active: true
        )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # The grid draws that cell disabled and gives it no hidden partner, so a
      # browser can never submit it ticked. This id can only arrive forged:
      # pushed at the component's own event rather than ticked in the grid.
      assert disabled?(html, source, ics)

      html = save_forged_cell(view, cell_id(source, target), source, ics)

      # The changeset knows exactly why — the target is a read-only
      # subscription — and saying so is the difference between an organiser
      # who unticks the cell and one who tries again. A grid save that
      # collapsed every failure into "could not be linked" would discard a
      # reason the schema had already worked out.
      assert html =~ "read-only subscription"
      assert SyncLink.list_links(user.id) == []
    end

    # The panel is translated; the refusal has to be too, or a non-English
    # organiser reads an English sentence inside an otherwise German page and
    # cannot tell whether it came from Tymeslot or from their calendar
    # provider.
    test "refuses that link in the organiser's own language", ctx do
      %{conn: conn, user: user, source: source, target: target} = ctx

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

      html = save_forged_cell(view, cell_id(source, target), source, ics)

      # Asserted against the catalogue rather than a literal, so the assertion
      # cannot drift from the translation that ships. Looked up in an explicit
      # German scope: the locale the view resolved lives in the view's process,
      # not this one.
      # The refusal that reaches the panel is the changeset's own — it names
      # the reason rather than shrugging — so this asserts against the
      # `errors` domain the schema writes its message into.
      msgid = "is a read-only subscription and cannot receive mirrored events"

      translated =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          Gettext.dgettext(TymeslotWeb.Gettext, "errors", msgid)
        end)

      refute translated == msgid,
             "the German catalogue has no translation for the refusal message"

      assert html =~ translated
      refute html =~ msgid
      assert SyncLink.list_links(user.id) == []
    end

    test "never offers a read-only subscription as a target", ctx do
      %{conn: conn, user: user, source: source, target: target} = ctx

      ics =
        insert(:calendar_integration,
          user: user,
          provider: "ics_url",
          name: "Team Feed",
          is_active: true
        )

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=sync_links")

      # A source it may be — reading a feed is the one thing every provider can
      # do — so it keeps its row and every cell along it stays available.
      refute disabled?(html, ics, source)
      refute disabled?(html, ics, target)

      # But never a target: its whole column is refused, whichever calendar is
      # doing the mirroring.
      assert disabled?(html, source, ics)
      assert disabled?(html, target, ics)
    end
  end
end
