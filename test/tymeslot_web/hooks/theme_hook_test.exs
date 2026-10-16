defmodule TymeslotWeb.Hooks.ThemeHookTest do
  @moduledoc """
  Unit tests for `ThemeHook.on_mount/4` focused on the graceful-default
  paths that the hook must satisfy when profile lookups fail.

  The existing `live/themes/theme_hook_test.exs` covers the positive
  end-to-end wiring (Quill and Rhythm video hooks render when the
  profile has matching `booking_theme` + a matching
  `theme_customization`). It does not cover the failure modes the
  hook silently swallows — notably the race where
  `Profiles.get_profile_by_username/1` returns `nil` because the user
  was deleted between route resolution (username extracted by the
  router) and LiveView mount. A regression that made that path raise
  would surface as a crashed scheduling page for any stale link.

  Dropped from the plan with rationale:

    * `feature_assigns_hook when feature checker module is absent /
      raises → safe defaults applied, no crash` — the premise is
      contradicted by production code.
      `TymeslotWeb.Hooks.FeatureAssignsHook` does not invoke a feature
      checker; it only reads
      `Application.get_env(:tymeslot, :feature_assigns, [])` — a list
      of `{key, default_value}` tuples — and assigns them. There is no
      module call to absent-or-raise. The actual checker,
      `Tymeslot.Features.check_access/2`, already has an explicit
      `try/rescue` (`features.ex:48–59`) and is wired into worker and
      context modules, not this hook. A downstream overlay's
      subscription hook that *does* override feature assigns is already
      covered by that overlay's own tests.

    * `nil booking_theme → default theme "1"` — the premise is
      contradicted by production code. `ProfileSchema.booking_theme`
      is defined with `default: Registry.default_theme_id()`
      (`profile_schema.ex:50`), so a profile row without a theme is
      impossible via Ecto. The `%{booking_theme: theme} when
      is_binary(theme)` guard in the hook is a defensive belt-and-
      braces against a state Ecto cannot emit.

    * The hook no longer reads `socket.private[:theme_id]`: no plug,
      router, or hook ever sets it.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :hooks
  @moduletag :themes

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Hooks.ThemeHook

  defp build_socket do
    %Socket{
      assigns: %{__changed__: %{}},
      endpoint: TymeslotWeb.Endpoint
    }
  end

  describe "on_mount/4 — username param with missing profile" do
    test "falls back to default theme when the user was deleted mid-mount" do
      # Race: the router matched `/:username` and handed "ghost" to the
      # mount, but the profile row has since been deleted. The hook
      # must not crash — stale links from crawlers or email clients
      # would otherwise 500 the scheduling page.
      assert {:cont, updated_socket} =
               ThemeHook.on_mount(:default, %{"username" => "ghost"}, %{}, build_socket())

      assert updated_socket.assigns.theme_id == "1"
    end

    test "uses the profile's booking_theme when one is configured" do
      user = insert(:user)
      insert(:profile, user: user, username: "rhythmuser", booking_theme: "2")

      assert {:cont, updated_socket} =
               ThemeHook.on_mount(:default, %{"username" => "rhythmuser"}, %{}, build_socket())

      assert updated_socket.assigns.theme_id == "2"
    end
  end

  describe "on_mount/4 — explicit theme precedence" do
    test "explicit theme param wins over profile lookup" do
      user = insert(:user)
      insert(:profile, user: user, username: "overridden", booking_theme: "1")

      assert {:cont, updated_socket} =
               ThemeHook.on_mount(
                 :default,
                 %{"theme" => "2", "username" => "overridden"},
                 %{},
                 build_socket()
               )

      # This guards against a regression where the hook order were
      # flipped — the explicit `theme` override is how the theme
      # picker in the dashboard previews non-active themes without
      # mutating the profile.
      assert updated_socket.assigns.theme_id == "2"
    end

    test "theme_id query param is used when no theme param is present" do
      assert {:cont, updated_socket} =
               ThemeHook.on_mount(:default, %{"theme_id" => "2"}, %{}, build_socket())

      assert updated_socket.assigns.theme_id == "2"
    end

    test "defaults to theme 1 when neither the params nor the organiser name a theme" do
      assert {:cont, updated_socket} =
               ThemeHook.on_mount(:default, %{}, %{}, build_socket())

      assert updated_socket.assigns.theme_id == "1"
    end
  end

  describe "on_mount/4: unknown theme ids" do
    test "an unknown ?theme= falls through to the organiser's theme" do
      user = insert(:user)
      insert(:profile, user: user, username: "rhythm-host", booking_theme: "2")

      assert {:cont, socket} =
               ThemeHook.on_mount(
                 :default,
                 %{"theme" => "9", "username" => "rhythm-host"},
                 %{},
                 build_socket()
               )

      assert socket.assigns.theme_id == "2"
    end

    test "an unknown ?theme= with no organiser falls back to the default theme" do
      assert {:cont, socket} =
               ThemeHook.on_mount(:default, %{"theme" => "9"}, %{}, build_socket())

      assert socket.assigns.theme_id == Catalog.default_id()
    end

    test "an organiser theme the registry does not know falls back to the default" do
      user = insert(:user)
      insert(:profile, user: user, username: "stale-theme", booking_theme: "999")

      assert {:cont, socket} =
               ThemeHook.on_mount(:default, %{"username" => "stale-theme"}, %{}, build_socket())

      assert socket.assigns.theme_id == "1"
    end
  end
end
