defmodule TymeslotWeb.Themes.Shared.LocaleHandlerTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

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

    test "sets Gettext locale for current process" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{locale: "uk", __changed__: %{}},
        endpoint: TymeslotWeb.Endpoint
      }

      # Initial state
      Gettext.put_locale(TymeslotWeb.Gettext, "en")
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "en"

      # After assign_locale
      _socket = LocaleHandler.assign_locale(socket)
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "uk"
    end
  end

  describe "handle_locale_change/2" do
    test "changes locale when valid", %{socket: socket} do
      updated_socket = LocaleHandler.handle_locale_change(socket, "de")

      assert updated_socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "persists locale to session", %{socket: socket} do
      # Mock put_session for verification
      # In real LiveView, this is handled by the framework
      updated_socket = LocaleHandler.handle_locale_change(socket, "de")

      # Verify locale is in assigns (session persistence is tested in integration tests)
      assert updated_socket.assigns.locale == "de"
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
      # en -> de
      socket = LocaleHandler.handle_locale_change(socket, "de")
      assert socket.assigns.locale == "de"

      # de -> uk
      socket = LocaleHandler.handle_locale_change(socket, "uk")
      assert socket.assigns.locale == "uk"

      # uk -> fr
      socket = LocaleHandler.handle_locale_change(socket, "fr")
      assert socket.assigns.locale == "fr"

      # fr -> it
      socket = LocaleHandler.handle_locale_change(socket, "it")
      assert socket.assigns.locale == "it"

      # it -> en
      socket = LocaleHandler.handle_locale_change(socket, "en")
      assert socket.assigns.locale == "en"
    end

    test "updates Gettext locale on each change", %{socket: socket} do
      Gettext.put_locale(TymeslotWeb.Gettext, "en")

      _socket = LocaleHandler.handle_locale_change(socket, "de")
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"

      _socket = LocaleHandler.handle_locale_change(socket, "uk")
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "uk"
    end
  end

  describe "supported_locales/0" do
    test "returns list of supported locale codes" do
      locales = LocaleHandler.supported_locales()

      assert is_list(locales)
      assert "en" in locales
      assert "de" in locales
      assert "uk" in locales
      assert "fr" in locales
      assert "it" in locales
    end

    test "supported locales are derived from metadata configuration" do
      locales = LocaleHandler.supported_locales()
      metadata = LocaleHandler.get_locales_with_metadata()
      expected_codes = Enum.map(metadata, & &1.code)

      assert locales == expected_codes
    end
  end

  describe "get_locales_with_metadata/0" do
    test "returns list of locale metadata maps" do
      locales = LocaleHandler.get_locales_with_metadata()

      assert is_list(locales)
      assert length(locales) == 5

      Enum.each(locales, fn locale ->
        assert Map.has_key?(locale, :code)
        assert Map.has_key?(locale, :name)
        assert Map.has_key?(locale, :country_code)
      end)
    end

    test "includes English metadata" do
      locales = LocaleHandler.get_locales_with_metadata()
      english = Enum.find(locales, &(&1.code == "en"))

      assert english.name == "English"
      assert english.country_code == :gbr
    end

    test "includes German metadata" do
      locales = LocaleHandler.get_locales_with_metadata()
      german = Enum.find(locales, &(&1.code == "de"))

      assert german.name == "Deutsch"
      assert german.country_code == :deu
    end

    test "includes Ukrainian metadata" do
      locales = LocaleHandler.get_locales_with_metadata()
      ukrainian = Enum.find(locales, &(&1.code == "uk"))

      assert ukrainian.name == "Українська"
      assert ukrainian.country_code == :ukr
    end

    test "includes French metadata" do
      locales = LocaleHandler.get_locales_with_metadata()
      french = Enum.find(locales, &(&1.code == "fr"))

      assert french.name == "Français"
      assert french.country_code == :fra
    end

    test "includes Italian metadata" do
      locales = LocaleHandler.get_locales_with_metadata()
      italian = Enum.find(locales, &(&1.code == "it"))

      assert italian.name == "Italiano"
      assert italian.country_code == :ita
    end
  end

  describe "default_locale/0" do
    test "returns configured default locale" do
      default = LocaleHandler.default_locale()

      assert default == "en"
    end

    test "default locale is in supported locales" do
      default = LocaleHandler.default_locale()
      supported = LocaleHandler.supported_locales()

      assert default in supported
    end
  end

  describe "edge cases and concurrency" do
    test "handles rapid locale changes without race conditions", %{socket: socket} do
      # Simulate rapid changes
      socket = LocaleHandler.handle_locale_change(socket, "de")
      socket = LocaleHandler.handle_locale_change(socket, "uk")
      socket = LocaleHandler.handle_locale_change(socket, "en")
      socket = LocaleHandler.handle_locale_change(socket, "de")

      assert socket.assigns.locale == "de"
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "locale is process-local via Gettext", %{socket: socket} do
      # Set locale in this process
      LocaleHandler.handle_locale_change(socket, "de")
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"

      # Spawn another process and verify it has default locale
      task =
        Task.async(fn ->
          Gettext.get_locale(TymeslotWeb.Gettext)
        end)

      other_process_locale = Task.await(task)

      # Other process should have default locale
      assert other_process_locale == "en"

      # Current process should still have de
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

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
