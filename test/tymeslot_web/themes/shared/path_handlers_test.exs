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
      assert path == "/johndoe?locale=de"
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
      assert path == "/johndoe/30-minutes?locale=uk"
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
      assert path == "/johndoe/60-minutes/book?locale=en"
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
      assert path == "/johndoe/thank-you?locale=de"
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
      assert path == "/?locale=en"
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
      assert path == "/john.doe@example.com?locale=en"
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
      assert path == "/johndoe?locale=de&reschedule_meeting_uid=abc-123"
    end

    test "omits the reschedule uid when it is an empty string" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: "1",
          reschedule_meeting_uid: ""
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "de")
      assert path == "/johndoe?locale=de"
    end

    test "carries the theme while previewing so a locale switch keeps the preview" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: "2",
          theme_preview: true
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "de")
      assert path == "/johndoe?locale=de&theme=2"
    end

    test "does not carry the theme for an ordinary visitor" do
      # Regression: `:theme_id` is always assigned, so emitting it unconditionally
      # put every visitor who switched language onto a `theme=` URL. That reads as a
      # preview downstream and fails the booking closed, silently making it
      # impossible to book after changing the language.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :booking,
          selected_duration: "30min",
          theme_id: "1",
          theme_preview: false
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "fr")

      assert path == "/johndoe/30-minutes/book?locale=fr"
      refute path =~ "theme="
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
