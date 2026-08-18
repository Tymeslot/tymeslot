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

  describe "assign_locale/1" do
    test "assigns locale from socket assigns" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{locale: "de", __changed__: %{}},
        endpoint: TymeslotWeb.Endpoint
      }

      socket = LocaleHandler.assign_locale(socket)

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "uses default locale when not present in assigns" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}},
        endpoint: TymeslotWeb.Endpoint
      }

      socket = LocaleHandler.assign_locale(socket)

      assert socket.assigns.locale == "en"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "en"
    end
  end

  describe "handle_locale_change/2" do
    test "changes locale when valid", %{socket: socket} do
      updated_socket = LocaleHandler.handle_locale_change(socket, "de")

      assert updated_socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "is idempotent - no change when locale already set", %{socket: socket} do
      socket = %{socket | assigns: Map.put(socket.assigns, :locale, "de")}
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      # Change to same locale
      updated_socket = LocaleHandler.handle_locale_change(socket, "de")

      # Should return socket unchanged (same reference)
      assert updated_socket == socket
      assert updated_socket.assigns.locale == "de"
    end

    test "rejects unsupported locale", %{socket: socket} do
      updated_socket = LocaleHandler.handle_locale_change(socket, "es")

      # Should remain unchanged
      assert updated_socket.assigns.locale == "en"
    end

    test "handles nil locale gracefully", %{socket: socket} do
      updated_socket = LocaleHandler.handle_locale_change(socket, nil)

      # Should remain unchanged
      assert updated_socket.assigns.locale == "en"
    end

    test "handles empty string locale", %{socket: socket} do
      updated_socket = LocaleHandler.handle_locale_change(socket, "")

      # Should remain unchanged
      assert updated_socket.assigns.locale == "en"
    end

    test "transitions between all supported locales", %{socket: socket} do
      # Drive the socket through every configured locale in turn, asserting each
      # transition takes effect. Derived from config so a locale change never
      # requires editing this test.
      refute Locales.supported_codes() == []

      Enum.reduce(Locales.supported_codes(), socket, fn code, socket ->
        socket = LocaleHandler.handle_locale_change(socket, code)
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

  describe "edge cases and concurrency" do
    test "handles socket without locale assign gracefully" do
      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}},
          endpoint: TymeslotWeb.Endpoint
        }

      updated_socket = LocaleHandler.handle_locale_change(socket, "de")

      assert updated_socket.assigns.locale == "de"
    end
  end
end
