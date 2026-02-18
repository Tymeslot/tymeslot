defmodule TymeslotWeb.Themes.Shared.PathHandlersTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true

  alias TymeslotWeb.Themes.Shared.PathHandlers

  describe "build_path_with_locale/2" do
  @moduletag :utils
    test "builds path for overview action" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: "1"
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "de")
      assert path == "/johndoe?locale=de&theme=1"
    end

    test "builds path for schedule action with duration" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :schedule,
          duration: "30min",
          theme_id: "2"
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "uk")
      assert path == "/johndoe/30-minutes?locale=uk&slug=30-minutes&theme=2"
    end

    test "builds path for booking action" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :booking,
          selected_duration: "60min",
          theme_id: "1"
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "en")
      assert path == "/johndoe/60-minutes/book?locale=en&slug=60-minutes&theme=1"
    end

    test "builds path for confirmation action" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :confirmation,
          theme_id: "2"
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "de")
      assert path == "/johndoe/thank-you?locale=de&theme=2"
    end

    test "handles missing username context by falling back to root" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: nil,
          live_action: :overview,
          theme_id: "1"
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "en")
      assert path == "/?locale=en&theme=1"
    end

    test "handles special characters in username" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "john.doe@example.com",
          live_action: :overview,
          theme_id: "1"
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "en")
      # Note: username in URL should be already encoded or handled by router,
      # but PathHandlers just joins them.
      assert path == "/john.doe@example.com?locale=en&theme=1"
    end

    test "omits theme and duration if not in assigns" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: nil,
          duration: nil
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "de")
      assert path == "/johndoe?locale=de"
    end
  end
end
