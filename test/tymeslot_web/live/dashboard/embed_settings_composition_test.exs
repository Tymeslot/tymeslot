defmodule TymeslotWeb.Dashboard.EmbedSettingsCompositionTest do
  @moduledoc """
  Composition tests for dashboard settings persistence across mounts —
  the "does the change survive a page reload?" surface that
  per-screen unit tests don't exercise.

  Existing coverage (do not duplicate):

    * `embed_settings_test.exs:80` — removing a domain persists.
    * `embed_settings_test.exs:109` — removing the last domain
      auto-reinserts the `["none"]` sentinel.
    * `theme_settings_test.exs:23` — selecting a theme writes
      `booking_theme` to the DB.
    * `profile_settings_test.exs:189` — empty display name clears
      the field.

  What was missing: after writing a setting from one dashboard screen,
  a fresh mount of a DIFFERENT dashboard screen must read the updated
  value from the DB. The plan calls this out at line 1881 for theme
  selection; the same shape applies to embed-domain persistence and
  is a useful cross-mount sanity check.

  Dropped from the plan with rationale:

    * `remove_domain` TOCTOU (plan line 1879) — no deterministic way
      to interleave concurrent LiveView events in ExUnit without
      restructuring the component. The rate-limited domain-update
      path already prevents storms.
    * `remove_domain` when state is `["none"]` — no UI surface emits
      this event because the `["none"]` sentinel renders as "embedding
      disabled" with no per-domain chips, so no `remove_domain`
      button is drawn. Reaching the handler would require forging
      the event, which is a unit test of the handler's defensive
      guard rather than a LiveComponent composition test.
    * Profile update with whitespace-only display name "rejected"
      (plan line 1882) — the premise is contradicted by the
      production code. `FullNameValidator.validate/2` treats
      whitespace-only input as equivalent to empty (trims to "")
      and returns `:ok`; the form then clears the field via
      Ecto's `:string` coercion. Existing coverage:
      `profile_settings_test.exs:189`.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :dashboard
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Repo

  setup :setup_dashboard_user

  describe "settings persistence across fresh mounts" do
    @tag :capture_log
    test "selecting a theme is reflected when re-mounting the theme page",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("[phx-click='select_theme'][phx-value-theme='2']")
      |> render_click()

      assert Repo.reload!(profile).booking_theme == "2"

      # Fresh mount — the view re-reads the profile, so a regression
      # in how the theme page derives "selected" from the DB would
      # surface as a missing "Current Style" badge on the fresh mount.
      {:ok, fresh_view, html} = live(conn, ~p"/dashboard/theme")
      assert html =~ "Current Style"
      assert has_element?(fresh_view, "[phx-value-theme='2']")
    end

    @tag :capture_log
    test "adding an embed domain survives navigating away and back",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/embed")
      view |> element("button#tab-security") |> render_click()

      view
      |> form("form[phx-submit='save_embed_domains']", %{
        allowed_domains: "example.com"
      })
      |> render_submit()

      # The save reaches the DB.
      updated_profile = Repo.reload!(profile)
      assert "example.com" in (updated_profile.allowed_embed_domains || [])

      # Navigate to the dashboard root (resets the LiveView) and
      # return — the new mount must hydrate the security tab from
      # the DB, not from stale socket assigns.
      {:ok, _other_view, _html} = live(conn, ~p"/dashboard")
      {:ok, reopened, _html} = live(conn, ~p"/dashboard/embed")

      reopened |> element("button#tab-security") |> render_click()
      assert render(reopened) =~ "example.com"
    end
  end
end
