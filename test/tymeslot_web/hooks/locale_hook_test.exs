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
        LocaleHook.on_mount(:default, %{"locale" => "de"}, %{"resolved_locale" => "en"}, socket())

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "falls back to the dead render's resolved locale, then the default" do
      {:cont, socket} = LocaleHook.on_mount(:default, %{}, %{"resolved_locale" => "de"}, socket())
      assert socket.assigns.locale == "de"

      {:cont, socket} = LocaleHook.on_mount(:default, %{}, %{}, socket())
      assert socket.assigns.locale == "en"
    end
  end

  describe "per-source validation (matching LocalePlug)" do
    test "an unsupported URL parameter falls through to the dead render's resolved locale" do
      # An unsupported "es" param must not be coerced to the default; the valid
      # "de" session locale (what LocalePlug resolved on the dead render) wins.
      {:cont, socket} =
        LocaleHook.on_mount(:default, %{"locale" => "es"}, %{"resolved_locale" => "de"}, socket())

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "ignores the retired locale key once the dead render has resolved one" do
      # Only the dead render's resolution counts; a stray session value (the
      # retired :locale key) must not be read as one.
      {:cont, socket} =
        LocaleHook.on_mount(
          :default,
          %{},
          %{"resolved_locale" => "en", "locale" => "de"},
          socket()
        )

      assert socket.assigns.locale == "en"
    end

    test "keeps a page rendered before the resolved locale existed in its language" do
      # A session signed before a deploy carries only the retired key.
      {:cont, socket} = LocaleHook.on_mount(:default, %{}, %{"locale" => "de"}, socket())
      assert socket.assigns.locale == "de"
    end

    test "an unsupported session locale with no other source falls back to the default" do
      {:cont, socket} = LocaleHook.on_mount(:default, %{}, %{"resolved_locale" => "xx"}, socket())
      assert socket.assigns.locale == "en"
    end
  end
end
