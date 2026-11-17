defmodule TymeslotWeb.Themes.Shared.LocaleHandlerTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  alias Tymeslot.Locales
  alias TymeslotWeb.Themes.Shared.LocaleHandler

  setup do
    # Create a minimal LiveView socket structure for testing
    socket = %Phoenix.LiveView.Socket{
      assigns: %{locale: "en", __changed__: %{}},
      endpoint: TymeslotWeb.Endpoint
    }

    {:ok, socket: socket}
  end

  describe "handle_locale_change/2" do
    test "changes locale when valid", %{socket: socket} do
      {:cont, updated_socket} = LocaleHandler.handle_locale_change(socket, "de")

      assert updated_socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "is idempotent - no change when locale already set", %{socket: socket} do
      socket = %{socket | assigns: Map.put(socket.assigns, :locale, "de")}
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      # Change to same locale
      {:cont, updated_socket} = LocaleHandler.handle_locale_change(socket, "de")

      # Should return socket unchanged (same reference)
      assert updated_socket == socket
      assert updated_socket.assigns.locale == "de"
    end

    test "rejects unsupported locale", %{socket: socket} do
      {:cont, updated_socket} = LocaleHandler.handle_locale_change(socket, "ja")

      # Should remain unchanged
      assert updated_socket.assigns.locale == "en"
    end

    test "handles nil locale gracefully", %{socket: socket} do
      {:cont, updated_socket} = LocaleHandler.handle_locale_change(socket, nil)

      # Should remain unchanged
      assert updated_socket.assigns.locale == "en"
    end

    test "handles empty string locale", %{socket: socket} do
      {:cont, updated_socket} = LocaleHandler.handle_locale_change(socket, "")

      # Should remain unchanged
      assert updated_socket.assigns.locale == "en"
    end

    test "transitions between all supported locales", %{socket: socket} do
      # Drive the socket through every configured locale in turn, asserting each
      # transition takes effect. Derived from config so a locale change never
      # requires editing this test.
      refute Locales.supported_codes() == []

      Enum.reduce(Locales.supported_codes(), socket, fn code, socket ->
        {:cont, socket} = LocaleHandler.handle_locale_change(socket, code)
        assert socket.assigns.locale == code
        socket
      end)
    end

    test "updates Gettext locale on each change", %{socket: socket} do
      Gettext.put_locale("en")
      refute Locales.supported_codes() == []

      Enum.each(Locales.supported_codes(), fn code ->
        LocaleHandler.handle_locale_change(socket, code)
        assert Gettext.get_locale(TymeslotWeb.Gettext) == code
      end)
    end
  end

  describe "handle_locale_change/3 on a page with an organiser's texts" do
    setup %{socket: socket} do
      profile = %Tymeslot.Profiles.ProfileSchema{
        content_locale: "en",
        translation_locales: ["de"],
        offer_all_locales: false
      }

      {:ok, socket: %{socket | assigns: Map.put(socket.assigns, :organizer_profile, profile)}}
    end

    test "reloads the page for an offered language", %{socket: socket} do
      url = "http://localhost/anna?locale=de"
      {:reload, updated} = LocaleHandler.handle_locale_change(socket, "de", url)

      assert updated.redirected == {:redirect, %{external: url, status: 302}}
      assert updated.assigns.locale == "en"
    end

    test "does nothing for the language already shown, so the reload cannot loop", %{
      socket: socket
    } do
      {:cont, updated} =
        LocaleHandler.handle_locale_change(socket, "en", "http://localhost/anna?locale=en")

      assert updated.redirected == nil
    end

    test "ignores a language the organiser does not offer", %{socket: socket} do
      {:cont, updated} =
        LocaleHandler.handle_locale_change(socket, "fr", "http://localhost/anna?locale=fr")

      assert updated.redirected == nil
      assert updated.assigns.locale == "en"
    end

    test "reloads a page whose ?locale= is not offered with the original in its URL", %{
      socket: socket
    } do
      socket = %{socket | assigns: Map.put(socket.assigns, :stale_locale_param, true)}
      url = "http://localhost/anna?locale=fr&timezone=Europe%2FBerlin"

      {:reload, updated} = LocaleHandler.handle_locale_change(socket, "fr", url)

      assert {:redirect, %{external: to}} = updated.redirected
      assert %{"locale" => "en", "timezone" => "Europe/Berlin"} = query_of(to)
    end
  end

  defp query_of(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  describe "edge cases and concurrency" do
    test "handles socket without locale assign gracefully" do
      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}},
          endpoint: TymeslotWeb.Endpoint
        }

      {:cont, updated_socket} = LocaleHandler.handle_locale_change(socket, "de")

      assert updated_socket.assigns.locale == "de"
    end
  end
end
