defmodule TymeslotWeb.Themes.Shared.PathHandlersTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  alias TymeslotWeb.Themes.Shared.PathHandlers

  describe "build_path_with_locale/2" do
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
      assert path == "/johndoe/30-minutes?locale=uk&theme=2"
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
      assert path == "/johndoe/60-minutes/book?locale=en&theme=1"
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

    test "carries the reschedule uid so a locale switch mid-reschedule keeps context" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: "1",
          reschedule_meeting_uid: "abc-123"
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "de")
      assert path == "/johndoe?locale=de&reschedule_meeting_uid=abc-123&theme=1"
    end
  end

  describe "organizer_scheduling_path/1" do
    test "returns path with username when organizer profile has username" do
      assigns = %{organizer_profile: %{username: "janedoe"}}
      assert PathHandlers.organizer_scheduling_path(assigns) == "/janedoe"
    end

    test "appends the reschedule uid when a meeting_uid is present" do
      assigns = %{organizer_profile: %{username: "janedoe"}, meeting_uid: "abc-123"}

      assert PathHandlers.organizer_scheduling_path(assigns) ==
               "/janedoe?reschedule_meeting_uid=abc-123"
    end

    test "omits the reschedule param when meeting_uid is blank" do
      assigns = %{organizer_profile: %{username: "janedoe"}, meeting_uid: ""}
      assert PathHandlers.organizer_scheduling_path(assigns) == "/janedoe"
    end

    test "falls back to root when username is empty" do
      assigns = %{organizer_profile: %{username: ""}}
      assert PathHandlers.organizer_scheduling_path(assigns) == "/"
    end

    test "falls back to root when organizer profile is nil" do
      assigns = %{organizer_profile: nil}
      assert PathHandlers.organizer_scheduling_path(assigns) == "/"
    end

    test "falls back to root when organizer profile is missing from assigns" do
      assert PathHandlers.organizer_scheduling_path(%{}) == "/"
    end
  end
end
