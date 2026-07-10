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
          %{"path_locale" => "de", "locale" => "en"},
          socket(%{current_user: %{locale: "en"}})
        )

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "user preference wins over the session locale without a path locale" do
      {:cont, socket} =
        AppLocaleHook.on_mount(
          :default,
          %{},
          %{"locale" => "en"},
          socket(%{current_user: %{locale: "de"}})
        )

      assert socket.assigns.locale == "de"
    end

    test "falls back to the session locale, then the default" do
      {:cont, socket} = AppLocaleHook.on_mount(:default, %{}, %{"locale" => "de"}, socket())
      assert socket.assigns.locale == "de"

      {:cont, socket} = AppLocaleHook.on_mount(:default, %{}, %{}, socket())
      assert socket.assigns.locale == "en"
    end

    test "an unsupported path locale is coerced to the default" do
      {:cont, socket} = AppLocaleHook.on_mount(:default, %{}, %{"path_locale" => "xx"}, socket())
      assert socket.assigns.locale == "en"
    end
  end
end
