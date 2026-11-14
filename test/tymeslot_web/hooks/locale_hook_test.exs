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
      # An unsupported "ja" param must not be coerced to the default; the valid
      # "de" session locale (what LocalePlug resolved on the dead render) wins.
      {:cont, socket} =
        LocaleHook.on_mount(:default, %{"locale" => "ja"}, %{"resolved_locale" => "de"}, socket())

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

  describe "the visitor's pick and the browser's languages" do
    test "the mount URL's ?locale= is the pick, over the dead render's" do
      session = %{"locale_choice" => "fr", "browser_locales" => ["de", "it"]}

      {:cont, socket} = LocaleHook.on_mount(:default, %{"locale" => "pl"}, session, socket())

      assert socket.assigns.locale_choice == "pl"
      assert socket.assigns.browser_locales == ["de", "it"]
      assert socket.assigns.locale_param == "pl"
    end

    test "without one, the dead render's pick, or none" do
      {:cont, socket} =
        LocaleHook.on_mount(:default, %{}, %{"locale_choice" => "fr"}, socket())

      assert socket.assigns.locale_choice == "fr"
      assert socket.assigns.locale_param == nil

      {:cont, socket} = LocaleHook.on_mount(:default, %{"locale" => "xx"}, %{}, socket())
      assert socket.assigns.locale_choice == nil
    end

    test "a session signed before the browser's languages were carried has its locale" do
      {:cont, socket} =
        LocaleHook.on_mount(:default, %{}, %{"resolved_locale" => "de"}, socket())

      assert socket.assigns.browser_locales == ["de"]
    end
  end
end
