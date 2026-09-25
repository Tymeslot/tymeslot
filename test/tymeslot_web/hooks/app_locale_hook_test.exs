defmodule TymeslotWeb.Hooks.AppLocaleHookTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Hooks.AppLocaleHook

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  describe "locale resolution precedence" do
    test "path locale from the live_session static map wins over the user preference" do
      {:cont, socket} =
        AppLocaleHook.on_mount(
          :default,
          %{},
          %{"path_locale" => "de", "ambient_locale" => "en"},
          socket(%{current_user: %{locale: "en"}})
        )

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "user preference wins over the ambient locale without a path locale" do
      {:cont, socket} =
        AppLocaleHook.on_mount(
          :default,
          %{},
          %{"ambient_locale" => "en"},
          socket(%{current_user: %{locale: "de"}})
        )

      assert socket.assigns.locale == "de"
    end

    test "falls back to the ambient locale, then the default" do
      {:cont, socket} =
        AppLocaleHook.on_mount(:default, %{}, %{"ambient_locale" => "de"}, socket())

      assert socket.assigns.locale == "de"

      {:cont, socket} = AppLocaleHook.on_mount(:default, %{}, %{}, socket())
      assert socket.assigns.locale == "en"
    end

    test "an unsupported path locale with no other source falls back to the default" do
      {:cont, socket} = AppLocaleHook.on_mount(:default, %{}, %{"path_locale" => "xx"}, socket())
      assert socket.assigns.locale == "en"
    end
  end

  describe "per-source validation (matching LocalePlug)" do
    test "an unsupported user locale falls through to the valid ambient locale" do
      # A stale "es" preference must not be coerced to the default; the valid
      # "de" ambient locale (what LocalePlug detected on the dead render) wins.
      {:cont, socket} =
        AppLocaleHook.on_mount(
          :default,
          %{},
          %{"ambient_locale" => "de"},
          socket(%{current_user: %{locale: "es"}})
        )

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "an unsupported path locale falls through to the user preference" do
      {:cont, socket} =
        AppLocaleHook.on_mount(
          :default,
          %{},
          %{"path_locale" => "xx", "ambient_locale" => "en"},
          socket(%{current_user: %{locale: "de"}})
        )

      assert socket.assigns.locale == "de"
    end
  end

  describe ":ambient_locale assign" do
    test "is the resolution without the user's saved preference" do
      {:cont, socket} =
        AppLocaleHook.on_mount(
          :default,
          %{},
          %{"ambient_locale" => "fr"},
          socket(%{current_user: %{locale: "de"}})
        )

      assert socket.assigns.locale == "de"
      assert socket.assigns.ambient_locale == "fr"
    end

    test "follows the path locale when the route carries one" do
      {:cont, socket} =
        AppLocaleHook.on_mount(
          :default,
          %{},
          %{"path_locale" => "it", "ambient_locale" => "it"},
          socket(%{current_user: %{locale: "de"}})
        )

      assert socket.assigns.ambient_locale == "it"
    end
  end
end
