defmodule TymeslotWeb.Live.Dashboard.EmbedSettingsTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :live
  @moduletag :security

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Plug.Conn
  alias Plug.Test
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  describe "embed settings component" do
    setup do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      profile = insert(:profile, user: user, username: "testuser", allowed_embed_domains: [])

      conn = log_in_user(build_conn(), user)

      {:ok, conn: conn, user: user, profile: profile}
    end

    test "displays embed options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      assert has_element?(view, "div", "Inline Embed")
      assert has_element?(view, "div", "Popup Modal")
      assert has_element?(view, "div", "Direct Link")
      assert has_element?(view, "div", "Floating Button")
    end

    test "shows security section when toggled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Security section tab panel should be hidden initially
      assert has_element?(view, "#panel-security[hidden]")

      # Click to show security section tab
      view
      |> element("button#tab-security")
      |> render_click()

      # Now it should be visible (hidden attribute removed)
      refute has_element?(view, "#panel-security[hidden]")
      assert has_element?(view, "input[name='allowed_domains']")
    end

    test "updates allowed domains successfully", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Show security section tab
      view |> element("button#tab-security") |> render_click()

      # Submit domains
      view
      |> form("form", %{allowed_domains: "example.com, test.org"})
      |> render_submit()

      # Check for success message
      assert render(view) =~ "Security settings saved successfully"

      # Verify domains were saved
      updated_profile = Repo.reload(profile)
      assert length(updated_profile.allowed_embed_domains) == 2
      assert "example.com" in updated_profile.allowed_embed_domains
      assert "test.org" in updated_profile.allowed_embed_domains

      # Verify they are displayed as tags
      html = render(view)
      assert html =~ "example.com"
      assert html =~ "test.org"
      # Check for remove buttons
      assert has_element?(
               view,
               "button[phx-click='remove_domain'][phx-value-domain='example.com']"
             )
    end

    test "removes a domain successfully", %{conn: conn, profile: profile} do
      # Set initial domains
      {:ok, _result} = Profiles.update_allowed_embed_domains(profile, ["example.com", "test.org"])

      {:ok, view, _html} = live(conn, "/dashboard/embed")
      view |> element("button#tab-security") |> render_click()

      # Click remove on one domain
      view
      |> element("button[phx-click='remove_domain'][phx-value-domain='example.com']")
      |> render_click()

      assert render(view) =~ "Domain removed successfully"

      # Verify in DB
      updated_profile = Repo.reload(profile)
      assert updated_profile.allowed_embed_domains == ["test.org"]

      # Verify UI (ensure we are on security tab)
      view |> element("button#tab-security") |> render_click()

      # The domain should no longer be in the list of tags
      # We check that test.org is still there but example.com is gone
      assert has_element?(view, "span", "test.org")

      # Since example.com is still in the flash message, we check for the specific tag structure
      refute has_element?(view, "span.inline-flex", "example.com")
    end

    test "removing the last domain automatically disables embedding", %{
      conn: conn,
      profile: profile
    } do
      {:ok, _result} = Profiles.update_allowed_embed_domains(profile, ["only-domain.com"])

      {:ok, view, _html} = live(conn, "/dashboard/embed")
      view |> element("button#tab-security") |> render_click()

      view
      |> element("button[phx-click='remove_domain'][phx-value-domain='only-domain.com']")
      |> render_click()

      assert render(view) =~ "Domain removed successfully"

      # With no domains left, embedding should be auto-disabled (sentinel ["none"])
      updated_profile = Repo.reload(profile)
      assert updated_profile.allowed_embed_domains == ["none"]
    end

    test "shows error for invalid domains", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view |> element("button#tab-security") |> render_click()

      view
      |> form("form", %{allowed_domains: "user@example.com"})
      |> render_submit()

      assert render(view) =~ "Invalid domain format"
    end

    test "shows error when too many domains", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view |> element("button#tab-security") |> render_click()

      # Create 21 domains
      many_domains = for i <- 1..21, do: "example#{i}.com"
      domains_str = Enum.join(many_domains, ", ")

      view
      |> form("form", %{allowed_domains: domains_str})
      |> render_submit()

      assert render(view) =~ "cannot have more than 20"
    end

    test "shows error for domain exceeding maximum length", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view |> element("button#tab-security") |> render_click()

      # Domain too long (> 255 characters)
      long_domain = String.duplicate("a", 252) <> ".com"

      view
      |> form("form", %{allowed_domains: long_domain})
      |> render_submit()

      assert render(view) =~ "exceed maximum length"
    end

    test "shows error when submitting a domain already in the whitelist", %{
      conn: conn,
      profile: profile
    } do
      {:ok, _result} = Profiles.update_allowed_embed_domains(profile, ["existing.com"])

      {:ok, view, _html} = live(conn, "/dashboard/embed")
      view |> element("button#tab-security") |> render_click()

      # Try to add a domain that is already whitelisted
      view
      |> form("form", %{allowed_domains: "existing.com"})
      |> render_submit()

      assert render(view) =~ "Already whitelisted"

      # Domain list should be unchanged
      assert Repo.reload(profile).allowed_embed_domains == ["existing.com"]
    end

    test "deduplicates case-variant domains in a single submission", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, "/dashboard/embed")
      view |> element("button#tab-security") |> render_click()

      # Submit the same domain with different casing
      view
      |> form("form", %{allowed_domains: "Example.COM, example.com"})
      |> render_submit()

      assert render(view) =~ "Security settings saved successfully"

      # Only one (lowercased) entry should be stored
      updated_profile = Repo.reload(profile)
      assert updated_profile.allowed_embed_domains == ["example.com"]
    end

    test "adding a domain when embedding is currently disabled replaces the sentinel", %{
      conn: conn,
      profile: profile
    } do
      # Start from the ["none"] disabled state
      {:ok, _result} = Profiles.update_allowed_embed_domains(profile, ["none"])

      {:ok, view, _html} = live(conn, "/dashboard/embed")
      view |> element("button#tab-security") |> render_click()

      view
      |> form("form", %{allowed_domains: "new-site.com"})
      |> render_submit()

      assert render(view) =~ "Security settings saved successfully"

      # ["none"] sentinel should be gone; only the new domain should be stored
      updated_profile = Repo.reload(profile)
      assert updated_profile.allowed_embed_domains == ["new-site.com"]
    end

    test "clears domains successfully", %{conn: conn, profile: profile} do
      # First set some domains
      {:ok, _result} =
        Profiles.update_allowed_embed_domains(profile, ["example.com", "test.org"])

      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view |> element("button#tab-security") |> render_click()

      # Should show disable button when domains are set
      assert has_element?(view, "button", "Disable All Embedding")

      # Click disable
      view
      |> element("button", "Disable All Embedding")
      |> render_click()

      assert render(view) =~ "Embedding is now disabled"

      # Verify domains were cleared (set to ["none"])
      updated_profile = Repo.reload(profile)
      assert updated_profile.allowed_embed_domains == ["none"]
    end

    test "shows rate limit error after too many domain updates", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")
      view |> element("button#tab-security") |> render_click()

      # Pre-exhaust the per-user rate limit via the API to avoid a race with
      # async: false tests that call RateLimiter.clear_all() in their setup
      # (which runs concurrently with async: true tests and would reset the counter).
      for _i <- 1..10 do
        RateLimiter.check_rate("embed_domain_update:#{user.id}", 60_000 * 60, 10)
      end

      # The next UI update must be rejected by the rate limiter
      view
      |> form("form", %{allowed_domains: "ratelimit-domain.com"})
      |> render_submit()

      assert render(view) =~ "Too many updates"
    end

    test "copies embed code to clipboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Click copy button for inline embed
      view
      |> element("button[phx-click='copy_code'][phx-value-type='inline']")
      |> render_click()

      assert render(view) =~ "Code copied to clipboard"
    end

    test "switches between embed types", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Initially inline should be selected
      assert render(view) =~ "Inline Mode"

      # Click on popup option
      view
      |> element(".embed-option-card[phx-value-type='popup']")
      |> render_click()

      # Popup should now be selected (check for visual indicator)
      html = render(view)
      assert html =~ "Popup Mode"
    end

    test "displays username in embed code snippets", %{conn: conn, profile: profile} do
      {:ok, _view, html} = live(conn, "/dashboard/embed")

      assert html =~ profile.username
      assert html =~ "/#{profile.username}"
    end

    test "shows current domain count in UI", %{conn: conn, profile: profile} do
      {:ok, _result} =
        Profiles.update_allowed_embed_domains(profile, [
          "example.com",
          "test.org",
          "subdomain.example.com"
        ])

      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view |> element("button#tab-security") |> render_click()

      # Should show the domains as tags
      assert has_element?(view, "span", "example.com")
      assert has_element?(view, "span", "test.org")
      assert has_element?(view, "span", "subdomain.example.com")
    end

    test "handles empty domain input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view |> element("button#tab-security") |> render_click()

      view
      |> form("form", %{allowed_domains: ""})
      |> render_submit()

      # Should not show success message because we reject empty input in handle_event
      refute render(view) =~ "Security settings saved successfully"
    end

    test "form input is preserved when domain update fails at validation", %{
      conn: conn,
      profile: profile
    } do
      # Fill 19 domains so the next add of 2 exceeds the 20-domain limit
      existing = for i <- 1..19, do: "existing#{i}.com"
      {:ok, _result} = Profiles.update_allowed_embed_domains(profile, existing)

      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view |> element("button#tab-security") |> render_click()

      # Submitting 2 new domains would bring total to 21 → should error
      view
      |> form("form", %{allowed_domains: "new1.example.com, new2.example.com"})
      |> render_submit()

      # Error should appear
      assert render(view) =~ "cannot have more than 20"

      # DB should be unchanged (19 domains, not 21)
      assert length(Repo.reload(profile).allowed_embed_domains) == 19
    end
  end

  describe "embed preview" do
    setup do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      profile = insert(:profile, user: user, username: "testuser")
      # Make sure profile is ready for scheduling
      insert(:meeting_type, user: user)

      conn = log_in_user(build_conn(), user)

      {:ok, conn: conn, user: user, profile: profile}
    end

    test "shows preview when toggled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Preview should be hidden initially (it's in a tab)
      assert has_element?(view, "#panel-preview[hidden]")

      # Click to show preview tab
      view
      |> element("button#tab-preview")
      |> render_click()

      # Now preview should be visible
      refute has_element?(view, "#panel-preview[hidden]")
      assert has_element?(view, "#live-preview-container")
    end
  end

  # Helper function to log in user for tests
  defp log_in_user(conn, user) do
    session = insert(:user_session, user: user)

    conn
    |> Test.init_test_session(%{})
    |> Conn.put_session(:user_token, session.token)
  end
end
