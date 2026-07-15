defmodule TymeslotWeb.Hooks.LocaleHookTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Hooks.LocaleHook

  defp socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
  end

  describe "locale resolution precedence" do
    test "URL parameter wins over the session locale" do
      {:cont, socket} =
        LocaleHook.on_mount(:default, %{"locale" => "de"}, %{"locale" => "en"}, socket())

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "falls back to the session locale, then the default" do
      {:cont, socket} = LocaleHook.on_mount(:default, %{}, %{"locale" => "de"}, socket())
      assert socket.assigns.locale == "de"

      {:cont, socket} = LocaleHook.on_mount(:default, %{}, %{}, socket())
      assert socket.assigns.locale == "en"
    end
  end

  describe "per-source validation (matching LocalePlug)" do
    test "an unsupported URL parameter falls through to the valid session locale" do
      # An unsupported "es" param must not be coerced to the default; the valid
      # "de" session locale (what LocalePlug resolved on the dead render) wins.
      {:cont, socket} =
        LocaleHook.on_mount(:default, %{"locale" => "es"}, %{"locale" => "de"}, socket())

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "an unsupported session locale with no other source falls back to the default" do
      {:cont, socket} = LocaleHook.on_mount(:default, %{}, %{"locale" => "xx"}, socket())
      assert socket.assigns.locale == "en"
    end
  end
end
