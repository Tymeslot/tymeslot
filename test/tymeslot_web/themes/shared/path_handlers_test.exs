defmodule TymeslotWeb.Themes.Shared.PathHandlersTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils
  @moduletag :themes

  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.Context
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.{Continuous, Paged, Transcript}
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

    test "does not carry the theme for an ordinary visitor" do
      # Regression guard for #84. `:theme_id` is always assigned, so emitting it
      # unconditionally put every visitor who switched language onto a `theme=`
      # URL. That was read as a preview downstream and failed the booking
      # closed: the visitor picked a slot, filled the form, submitted, and
      # nothing happened.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :booking,
          selected_duration: "30min",
          theme_id: "1",
          theme_preview: false,
          owner_preview: false
        }
      }

      path = PathHandlers.build_path_with_locale(socket, "fr")

      assert path == "/johndoe/30-minutes/book?locale=fr"
      refute path =~ "theme="
      refute path =~ "preview"
    end

    # A paged journey's switcher shows on its first moment only, before any
    # choice; a choice left behind by going back to it is not carried.
    test "carries no choice on a paged journey" do
      for {navigator, live_action} <- [{Paged, :overview}, {Paged, :schedule}] do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{
            username_context: "johndoe",
            live_action: live_action,
            journey: %Journey{navigator: navigator, moments: [], outcomes: %{}},
            duration: "30min",
            selected_duration: "30min",
            selected_date: "2027-03-12",
            selected_time: "9:00 AM",
            user_timezone: "America/New_York"
          }
        }

        assert URI.parse(PathHandlers.build_path_with_locale(socket, "de")).query == "locale=de"
      end
    end

    test "carries the choices on a page that opens its moments by itself" do
      for navigator <- [Continuous, Transcript] do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{
            username_context: "johndoe",
            live_action: :overview,
            journey: %Journey{navigator: navigator, moments: [], outcomes: %{}},
            selected_duration: "30min",
            selected_date: "2027-03-12",
            selected_time: "9:00 AM",
            user_timezone: "America/New_York"
          }
        }

        path = PathHandlers.build_path_with_locale(socket, "de")

        assert URI.parse(path).path == "/johndoe"

        assert URI.decode_query(URI.parse(path).query) == %{
                 "locale" => "de",
                 "duration" => "30-minutes",
                 "date" => "2027-03-12",
                 "time" => "9:00 AM",
                 "visitor_timezone" => "America/New_York"
               }
      end
    end

    # A switch on the confirmation must not land on the details for the
    # slot just booked.
    test "carries no choice from an outcome" do
      for outcome <- [:confirmation, :awaiting_payment] do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{
            username_context: "johndoe",
            live_action: :overview,
            current_state: outcome,
            journey: %Journey{navigator: Continuous, moments: [], outcomes: %{}},
            selected_duration: "30min",
            selected_date: "2027-03-12",
            selected_time: "9:00 AM",
            user_timezone: "America/New_York"
          }
        }

        assert PathHandlers.build_path_with_locale(socket, "de") == "/johndoe?locale=de"
      end
    end

    test "carries no time without its day" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :schedule,
          duration: "30min",
          journey: %Journey{navigator: Continuous, moments: [], outcomes: %{}},
          selected_time: "9:00 AM"
        }
      }

      assert PathHandlers.build_path_with_locale(socket, "de") == "/johndoe/30-minutes?locale=de"
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

  describe "build_path_with_locale/2 inside an owner preview" do
    # A locale switch is a full external redirect, so the LiveView that comes
    # back has no assigns and knows only what the URL carries. The preview
    # session therefore has to be rebuilt in the query string as a set: the
    # claim, the token, and the previewed theme. Dropping any one of them
    # changes what a booking does.

    test "carries the claim, the token and the previewed theme" do
      socket = preview_socket(theme_preview: true, preview_token: "signed-token")

      path = PathHandlers.build_path_with_locale(socket, "de")
      params = query_params(path)

      assert params["locale"] == "de"
      assert params["preview"] == "true"
      assert params["preview_token"] == "signed-token"
      assert params["theme"] == "2"
    end

    test "keeps simulating rather than booking for real after the switch" do
      # The load-bearing one. Without `preview` and `preview_token` in the
      # redirect, the owner lands on a page that still looks like their preview
      # but persists a real meeting they never see, which is precisely what the
      # fail-closed branch exists to prevent.
      socket = preview_socket(theme_preview: true, preview_token: "signed-token")

      params = socket |> PathHandlers.build_path_with_locale("de") |> query_params()

      assert params["preview"] == "true"
      assert params["preview_token"] == "signed-token"
    end

    test "carries the claim even once the token has gone, so the booking still fails closed" do
      # An expired token must not silently downgrade the page to a real
      # booking. The claim survives on its own and the submission is blocked.
      socket = preview_socket(theme_preview: true, preview_token: nil)

      params = socket |> PathHandlers.build_path_with_locale("de") |> query_params()

      assert params["preview"] == "true"
      refute Map.has_key?(params, "preview_token")
    end

    test "a verified owner counts as a preview even when the URL claim was dropped" do
      # `:owner_preview` is sticky across internal navigation while
      # `:theme_preview` is re-read from the params, so mid-flow only the
      # former may be set. Either is enough to mean "this is a preview".
      socket = preview_socket(theme_preview: false, preview_token: "signed-token")
      socket = put_in(socket.assigns[:owner_preview], true)

      params = socket |> PathHandlers.build_path_with_locale("de") |> query_params()

      assert params["preview"] == "true"
      assert params["preview_token"] == "signed-token"
    end
  end

  describe "build_path_with_locale/2 inside an embed" do
    # The redirect is a full page load inside the iframe. Unless it is rebuilt
    # as an embed URL, the page that comes back has no embed token (a paid
    # booking tries to open Stripe Checkout inside the frame) and the embed's
    # layout, accent colour and theme fall back to the organiser's defaults.

    test "carries the embed flag, parent origin, theme, layout and colour" do
      params =
        embed_socket(embed_layout: :column, theme_overrides: %{primary_color: "#e11d48"})
        |> PathHandlers.build_path_with_locale("de")
        |> query_params()

      assert params == %{
               "locale" => "de",
               "embed" => "1",
               "parent-origin" => "https://embedder.test",
               "theme" => "2",
               "layout" => "column",
               "primary-color" => "#e11d48"
             }
    end

    test "leaves out a layout and a colour the page did not accept" do
      # The theme context drops an invalid `primary-color` and any layout but
      # `column`; the redirect reads the context, so nothing invalid is echoed.
      params =
        embed_socket(embed_layout: :default, theme_overrides: %{})
        |> PathHandlers.build_path_with_locale("de")
        |> query_params()

      assert params == %{
               "locale" => "de",
               "embed" => "1",
               "parent-origin" => "https://embedder.test",
               "theme" => "2"
             }
    end

    test "an invalid colour on the embed URL is not carried into the redirect" do
      context = Context.from_params(%{"theme" => "2", "primary-color" => "red;}"})

      params =
        embed_socket([])
        |> Map.update!(:assigns, &Map.merge(&1, Context.to_assigns(context)))
        |> PathHandlers.build_path_with_locale("de")
        |> query_params()

      refute Map.has_key?(params, "primary-color")
      assert params["embed"] == "1"
      assert params["theme"] == "2"
    end

    test "does not turn an embedded visitor into a previewer" do
      params =
        embed_socket(theme_preview: false, owner_preview: false)
        |> PathHandlers.build_path_with_locale("de")
        |> query_params()

      refute Map.has_key?(params, "preview")
      refute Map.has_key?(params, "preview_token")
      refute PreviewMode.claimed?(params)
    end

    test "a standalone page carries none of the embed parameters" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: "2",
          embed_layout: :column,
          theme_overrides: %{primary_color: "#e11d48"},
          embed_parent_origin: "https://embedder.test"
        }
      }

      assert PathHandlers.build_path_with_locale(socket, "de") == "/johndoe?locale=de"
    end
  end

  describe "calendar_ics_path/1" do
    test "points at the meeting's download under the organiser's page" do
      assert PathHandlers.calendar_ics_path(%{
               username_context: "hostuser",
               meeting_uid: "abc123"
             }) ==
               "/hostuser/meeting/abc123/calendar.ics"
    end

    test "is nil until the meeting exists" do
      assert PathHandlers.calendar_ics_path(%{username_context: "hostuser", meeting_uid: nil}) ==
               nil

      assert PathHandlers.calendar_ics_path(%{username_context: "hostuser", meeting_uid: ""}) ==
               nil
    end

    test "is nil without the organiser's page to hang it from" do
      assert PathHandlers.calendar_ics_path(%{username_context: nil, meeting_uid: "abc123"}) ==
               nil

      assert PathHandlers.calendar_ics_path(%{username_context: "", meeting_uid: "abc123"}) == nil
      assert PathHandlers.calendar_ics_path(%{}) == nil
    end
  end

  defp preview_socket(opts) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        username_context: "johndoe",
        live_action: :overview,
        theme_id: "2",
        theme_preview: Keyword.fetch!(opts, :theme_preview),
        owner_preview: false,
        preview_token: Keyword.fetch!(opts, :preview_token)
      }
    }
  end

  defp embed_socket(overrides) do
    assigns =
      Map.merge(
        %{
          username_context: "johndoe",
          live_action: :overview,
          theme_id: "2",
          embedded: true,
          embed_parent_origin: "https://embedder.test",
          embed_layout: :default,
          theme_overrides: %{}
        },
        Map.new(overrides)
      )

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  defp query_params(path) do
    path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end
end
