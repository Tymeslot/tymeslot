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
      |> form("form[phx-submit='save_embed_domains']", %{allowed_domains: "example.com, test.org"})
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
      |> form("form[phx-submit='save_embed_domains']", %{allowed_domains: "user@example.com"})
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
      |> form("form[phx-submit='save_embed_domains']", %{allowed_domains: domains_str})
      |> render_submit()

      assert render(view) =~ "cannot have more than 20"
    end

    test "shows error for domain exceeding maximum length", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view |> element("button#tab-security") |> render_click()

      # Domain too long (> 255 characters)
      long_domain = String.duplicate("a", 252) <> ".com"

      view
      |> form("form[phx-submit='save_embed_domains']", %{allowed_domains: long_domain})
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
      |> form("form[phx-submit='save_embed_domains']", %{allowed_domains: "existing.com"})
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
      |> form("form[phx-submit='save_embed_domains']", %{
        allowed_domains: "Example.COM, example.com"
      })
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
      |> form("form[phx-submit='save_embed_domains']", %{allowed_domains: "new-site.com"})
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

    test "copies embed code to clipboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Click copy button for inline embed (default state — no customisations)
      view
      |> element("button[phx-click='copy_code'][phx-value-type='inline']")
      |> render_click()

      assert render(view) =~ "Code copied to clipboard"
    end

    test "copies embed code with customisations applied", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Apply customisations — switch to the centred "default" layout so the
      # override is emitted into the snippet (column is the embed default and
      # produces a clean snippet without a data-layout attribute).
      view
      |> form("form[phx-change='update_customisation']", %{
        "customise" => %{"layout" => "default", "initial_height" => "500", "max_width" => "900"}
      })
      |> render_change()

      view
      |> element("button[phx-click='copy_code'][phx-value-type='inline']")
      |> render_click()

      assert_push_event(view, "copy-to-clipboard", %{text: text})
      assert text =~ ~s(data-layout="default")
      assert text =~ ~s(data-initial-height="500")
      assert text =~ ~s(data-max-width="900")
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
      |> form("form[phx-submit='save_embed_domains']", %{allowed_domains: ""})
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
      |> form("form[phx-submit='save_embed_domains']", %{
        allowed_domains: "new1.example.com, new2.example.com"
      })
      |> render_submit()

      # Error should appear
      assert render(view) =~ "cannot have more than 20"

      # DB should be unchanged (19 domains, not 21)
      assert length(Repo.reload(profile).allowed_embed_domains) == 19
    end
  end

  describe "customisation controls" do
    setup do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      profile = insert(:profile, user: user, username: "customuser")
      conn = log_in_user(build_conn(), user)

      {:ok, conn: conn, profile: profile}
    end

    test "renders the customise panel with three controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      assert has_element?(view, "select#embed-layout")
      assert has_element?(view, "input#embed-initial-height")
      assert has_element?(view, "input#embed-max-width")
    end

    test "customise controls are wrapped in a phx-change form", %{conn: conn} do
      # Regression guard: LiveView throws when phx-change fires on an input
      # outside a <form>, so the dropdown silently breaks if the form
      # wrapper is removed.
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      assert has_element?(view, "form[phx-change='update_customisation'] select#embed-layout")

      assert has_element?(
               view,
               "form[phx-change='update_customisation'] input#embed-initial-height"
             )

      assert has_element?(view, "form[phx-change='update_customisation'] input#embed-max-width")
    end

    test "embed snippets are clean by default (column is the embed default)", %{conn: conn} do
      # Column is the new default because embed.js sets ?embed=1 on every
      # iframe URL and the server picks :column for embedded contexts. Code
      # snippets inside <pre><code> blocks are HTML-escaped, so a layout
      # attribute would appear as `data-layout=&quot;column&quot;` —
      # the live-preview hook's own data-layout attribute is unescaped, so
      # we target the escaped form to focus the assertion on snippet copy.
      #
      # The link snippet is intentionally NOT covered here — it points to
      # the standalone booking page (no ?embed=1), where :default is the
      # server default, so picking "Column" in the dashboard correctly
      # emits ?layout=column to override.
      {:ok, _view, html} = live(conn, "/dashboard/embed")

      refute html =~ "data-layout=&quot;column&quot;"
      refute html =~ "layout: &#39;column&#39;"
    end

    test "switching to default layout emits the override on every snippet", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view
      |> form("form[phx-change='update_customisation']", %{
        "customise" => %{"layout" => "default"}
      })
      |> render_change()

      html = render(view)

      # Inline snippet picks up data-layout="default" — HTML-escaped inside
      # the <pre><code> block.
      assert html =~ "data-layout=&quot;default&quot;"
      # Popup/floating JS snippets emit `layout: 'default'`, with HTML-escaped
      # apostrophes inside the <pre><code> code block.
      assert html =~ "layout: &#39;default&#39;"
      # Link snippet goes to the standalone page (no ?embed=1) where default
      # is already the standalone default — no override needed.
      refute html =~ "?layout=default"
    end

    test "switching to column on the link snippet adds ?layout=column", %{conn: conn} do
      # The link snippet opens the booking page standalone, where the server
      # default is :default. A user who wants their /username link to render
      # wide needs the explicit ?layout=column override.
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view
      |> form("form[phx-change='update_customisation']", %{
        "customise" => %{"layout" => "column"}
      })
      |> render_change()

      assert render(view) =~ "?layout=column"
    end

    test "rejects invalid layout values and falls back to column", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Target the form element directly so phx-target={@myself} routes the
      # event to the component, and bypass the `form/2` helper's option
      # validation to test the server-side allowlist against tampered payloads.
      view
      |> element("form[phx-change='update_customisation']")
      |> render_change(%{"customise" => %{"layout" => "mosaic"}})

      html = render(view)
      # Invalid value falls back to "column" — clean snippet, no overrides.
      # Check the HTML-escaped form so the assertions target snippet copy,
      # not the live-preview hook's data-layout attribute.
      # Positive confirmation that the fallback landed in column state: the
      # link snippet emits ?layout=column (column overrides the standalone
      # default, which is :default). Without this a silent no-op would pass.
      assert html =~ "?layout=column"
      refute html =~ "data-layout=&quot;default&quot;"
      refute html =~ "layout: &#39;default&#39;"
      refute html =~ "layout: &#39;mosaic&#39;"
    end

    test "initial_height appears in the inline snippet when set", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view
      |> form("form[phx-change='update_customisation']", %{
        "customise" => %{"initial_height" => "600"}
      })
      |> render_change()

      html = render(view)
      assert html =~ ~s(data-initial-height=\"600\")
    end

    test "max_width appears in inline, popup, and floating snippets", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      view
      |> form("form[phx-change='update_customisation']", %{
        "customise" => %{"max_width" => "1200"}
      })
      |> render_change()

      html = render(view)
      # Inline snippet: data-max-width attribute on the div
      assert html =~ ~s(data-max-width=\"1200\")
      # Popup/floating snippets: maxWidth in the JS options object
      assert html =~ "maxWidth: 1200"
    end

    test "blank values clear the customisation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/embed")

      # Set a value, then clear it
      view
      |> form("form[phx-change='update_customisation']", %{
        "customise" => %{"initial_height" => "600"}
      })
      |> render_change()

      view
      |> form("form[phx-change='update_customisation']", %{
        "customise" => %{"initial_height" => ""}
      })
      |> render_change()

      html = render(view)
      refute html =~ "data-initial-height"
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
