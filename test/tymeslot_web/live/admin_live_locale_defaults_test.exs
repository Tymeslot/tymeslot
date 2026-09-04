defmodule TymeslotWeb.AdminLiveLocaleDefaultsTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :live
  @moduletag :i18n

  import Phoenix.LiveViewTest
  import Tymeslot.AdminPageHelpers
  import Tymeslot.AppSettingsEnvHelpers

  alias Tymeslot.AppSettings
  alias Tymeslot.Locales

  # Snapshots and restores every AppSettings key, the two locale defaults
  # included, so a language chosen here cannot leak into another test's
  # rendering.
  setup :restore_app_settings_env

  setup :admin_conn

  # The active button is the one rendered with aria-pressed="true"; returns
  # its locale code ("" for the instance-default option), or :none if that
  # surface highlights nothing at all.
  defp active_locale_button(html, key) do
    regex = ~r/phx-value-key="#{key}"\s+phx-value-locale="([a-z]*)"[^>]*aria-pressed="true"/

    case Regex.run(regex, html) do
      [_all, code] -> code
      nil -> :none
    end
  end

  describe "the Localisation section" do
    test "renders a Localisation section with one button per language per surface",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/general")

      assert html =~ "Localisation"
      assert html =~ "Dashboard fallback language"
      assert html =~ "Booking page fallback language"

      # Every configured language is offered on both surfaces, plus the
      # instance-default option: 2 surfaces x (6 languages + 1 default).
      buttons = Regex.scan(~r/phx-value-locale="[a-z]*"/, html)
      assert length(buttons) == 2 * (length(Locales.supported_codes()) + 1)

      # Named by their endonyms, and the no-override option names the language
      # it actually resolves to rather than an abstract "instance default".
      assert html =~ "Deutsch"
      assert html =~ "Install default (English)"
    end

    test "the unset surface highlights the instance-default button, not a language",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/general")

      assert active_locale_button(html, "admin_default_locale") == ""
      assert active_locale_button(html, "booking_default_locale") == ""
    end

    test "choosing a language moves the highlight onto it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/general")

      html =
        render_click(lv, "set_locale", %{"key" => "booking_default_locale", "locale" => "de"})

      assert active_locale_button(html, "booking_default_locale") == "de"
      # The other surface is untouched, so its default stays highlighted.
      assert active_locale_button(html, "admin_default_locale") == ""
    end

    test "choosing a booking fallback language persists it and takes effect immediately",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/general")

      html =
        render_click(lv, "set_locale", %{
          "key" => "booking_default_locale",
          "locale" => "de"
        })

      assert html =~ "Booking page fallback language updated."
      assert %{booking_default_locale: "de"} = AppSettings.get!()
      assert Locales.booking_default_locale() == "de"

      # The two surfaces are independent: setting one must not move the other.
      assert Locales.admin_default_locale() == Locales.default_locale()
    end

    test "choosing an admin fallback language persists it independently", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/general")

      html =
        render_click(lv, "set_locale", %{"key" => "admin_default_locale", "locale" => "fr"})

      assert html =~ "Dashboard fallback language updated."
      assert Locales.admin_default_locale() == "fr"
      assert Locales.booking_default_locale() == Locales.default_locale()
    end

    test "clearing the select removes the override", %{conn: conn} do
      {:ok, _settings} = AppSettings.update(%{admin_default_locale: "de"})

      {:ok, lv, _html} = live(conn, ~p"/admin/general")

      render_click(lv, "set_locale", %{"key" => "admin_default_locale", "locale" => ""})

      assert %{admin_default_locale: nil} = AppSettings.get!()
      assert Locales.admin_default_locale() == Locales.default_locale()
    end

    test "a locale code outside the supported set is refused with an inline error",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/general")

      html =
        render_click(lv, "set_locale", %{"key" => "booking_default_locale", "locale" => "zz"})

      assert html =~ "Choose one of the supported languages."
      assert %{booking_default_locale: nil} = AppSettings.get!()
    end
  end
end
