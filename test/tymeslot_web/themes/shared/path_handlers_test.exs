defmodule TymeslotWeb.Themes.Shared.PathHandlersTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils
  @moduletag :themes

  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.{Continuous, Transcript}
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
    # A paged journey does not move on by itself, so the moment on screen
    # rides along, and the page mounted from the URL resumes on it.
    test "carries the choices and the moment on screen on a paged journey" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :overview,
          journey: classic_journey(),
          current_state: :booking,
          selected_duration: "30min",
          selected_date: "2027-03-12",
          selected_time: "9:00 AM",
          chosen_length_minutes: 45,
          user_timezone: "America/New_York"
        }
      }

      assert URI.decode_query(URI.parse(PathHandlers.build_path_with_locale(socket, "de")).query) ==
               %{
                 "locale" => "de",
                 "duration" => "30-minutes",
                 "date" => "2027-03-12",
                 "time" => "9:00 AM",
                 "minutes" => "45",
                 "visitor_timezone" => "America/New_York",
                 "step" => "booking"
               }
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

    test "carries the token of the invitation the page holds" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :schedule,
          duration: "30min",
          invitation: %{token: "held-token"},
          page_query_params: %{"invite" => "url-token"}
        }
      }

      assert PathHandlers.build_path_with_locale(socket, "de") ==
               "/johndoe/30-minutes?invite=held-token&locale=de"
    end

    test "carries the URL's token when the page holds no invitation" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          live_action: :schedule,
          duration: "30min",
          invitation: nil,
          page_query_params: %{"invite" => "url-token"}
        }
      }

      assert PathHandlers.build_path_with_locale(socket, "de") ==
               "/johndoe/30-minutes?invite=url-token&locale=de"
    end
  end

  describe "choices_query/1" do
    # The page's own query (an embed's parameters, a tracking tag) stays; the
    # choices it arrived with give way to the ones made since.
    test "replaces the arrival's choices with the current ones and keeps the rest" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          live_action: :schedule,
          journey: classic_journey(),
          current_state: :schedule,
          page_query_params: %{
            "embed" => "1",
            "utm_source" => "newsletter",
            "date" => "2027-03-01",
            "time" => "2:00 PM",
            "step" => "booking"
          },
          selected_date: "2027-03-12",
          selected_time: nil
        }
      }

      assert PathHandlers.choices_query(socket) == %{
               "embed" => "1",
               "utm_source" => "newsletter",
               "date" => "2027-03-12",
               "step" => "schedule"
             }
    end

    # A reload of the confirmation must not land on the details for the slot
    # just booked.
    test "carries no choice on an outcome" do
      for outcome <- [:confirmation, :awaiting_payment] do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{
            live_action: :overview,
            journey: classic_journey(),
            current_state: outcome,
            page_query_params: %{"embed" => "1", "step" => "booking", "minutes" => "45"},
            selected_duration: "30min",
            selected_date: "2027-03-12",
            selected_time: "9:00 AM",
            chosen_length_minutes: 45,
            user_timezone: "America/New_York"
          }
        }

        assert PathHandlers.choices_query(socket) == %{"embed" => "1"}, "on #{outcome}"
      end
    end

    # The booking spent the invitation; the address bar is copied and kept
    # in history.
    test "keeps the invitation token before the confirmation and drops it there" do
      assigns = %{
        live_action: :schedule,
        journey: classic_journey(),
        page_query_params: %{"embed" => "1", "invite" => "inv-tok"}
      }

      booking = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :current_state, :booking)}
      done = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :current_state, :confirmation)}

      assert PathHandlers.choices_query(booking)["invite"] == "inv-tok"
      assert PathHandlers.choices_query(done) == %{"embed" => "1"}
    end
  end

  describe "facts_address/1" do
    test "drops the invitation token on the confirmation only" do
      assigns = %{
        username_context: "johndoe",
        page_query_params: %{"invite" => "inv-tok"},
        selected_duration: "30-minutes"
      }

      assert PathHandlers.facts_address(Map.put(assigns, :current_state, :schedule)) ==
               "/johndoe/30-minutes?invite=inv-tok"

      assert PathHandlers.facts_address(Map.put(assigns, :current_state, :confirmation)) ==
               "/johndoe/thank-you"
    end
  end

  describe "restart_path/2" do
    # A fresh booking keeps the meeting type, never the last booking's slot.
    test "drops the slot the URL carried and keeps the page's own query" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          page_query_params: %{
            "embed" => "1",
            "duration" => "30-minutes",
            "date" => "2027-03-12",
            "time" => "9:00 AM",
            "minutes" => "45",
            "step" => "booking",
            "reschedule_meeting_uid" => "abc"
          }
        }
      }

      path = PathHandlers.restart_path(socket)

      assert URI.parse(path).path == "/johndoe"

      assert URI.decode_query(URI.parse(path).query) == %{
               "embed" => "1",
               "duration" => "30-minutes"
             }
    end

    # The confirmation's address no longer carries the token, so the restart
    # names the invitation the page holds, whose gate then says it is spent.
    test "names the invitation the page holds" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          username_context: "johndoe",
          invitation: %{token: "inv-tok"},
          page_query_params: %{"embed" => "1"}
        }
      }

      assert URI.decode_query(URI.parse(PathHandlers.restart_path(socket)).query) == %{
               "embed" => "1",
               "invite" => "inv-tok"
             }
    end
  end

  defp classic_journey do
    Journey.new(
      Journey.classic(%{
        overview: Overview,
        schedule: Schedule,
        questions: Questions,
        booking: Booking,
        confirmation: Confirmation
      })
    )
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

  describe "facts_path/1" do
    test "follows what the booking knows, not the screen" do
      base = %{username_context: "ana", current_state: :offer}

      assert PathHandlers.facts_path(base) == "/ana"

      assert PathHandlers.facts_path(Map.put(base, :selected_duration, "intro-call")) ==
               "/ana/intro-call"

      assert PathHandlers.facts_path(
               Map.merge(base, %{
                 selected_duration: "intro-call",
                 selected_date: "2030-03-06",
                 selected_time: "10:30 AM"
               })
             ) == "/ana/intro-call/book"

      assert PathHandlers.facts_path(%{base | current_state: :confirmation}) == "/ana/thank-you"
    end

    test "takes the meeting type's own slug, encoded as a path segment" do
      assigns = %{
        username_context: "ana",
        current_state: :offer,
        selected_duration: "30-minutes",
        meeting_type: %{slug: "café chat", name: "Café chat"}
      }

      assert PathHandlers.facts_path(assigns) == "/ana/caf%C3%A9%20chat"
    end

    test "is nil without an organiser" do
      assert PathHandlers.facts_path(%{selected_duration: "intro-call"}) == nil
    end
  end

  describe "facts_query/1" do
    test "keeps the page's own parameters and drops what the facts say" do
      assigns = %{
        page_query_params: %{
          "timezone" => "Etc/UTC",
          "date" => "2030-03-06",
          "time" => "10:00 AM",
          "duration" => "30"
        },
        reschedule_meeting_uid: nil,
        reschedule_seat_token: nil
      }

      assert PathHandlers.facts_query(assigns) == "timezone=Etc%2FUTC"
    end

    test "never carries a confirmation link's name, email or meeting" do
      assigns = %{
        page_query_params: %{
          "embed" => "true",
          "name" => "Ana",
          "email" => "ana@example.com",
          "meeting_uid" => "m-1"
        }
      }

      assert PathHandlers.facts_query(assigns) == "embed=true"
    end

    test "keeps a reschedule while it lasts, and drops it once abandoned" do
      query = %{"reschedule_meeting_uid" => "m-1"}

      assert PathHandlers.facts_query(%{page_query_params: query, reschedule_meeting_uid: "m-1"}) ==
               "reschedule_meeting_uid=m-1"

      assert PathHandlers.facts_query(%{page_query_params: query, reschedule_meeting_uid: nil}) ==
               nil
    end
  end

  defp query_params(path) do
    path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  defp demo_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            username_context: "demo-page",
            live_action: :overview,
            demo_theme_switcher: true,
            organizer_profile: %{booking_theme: "1"}
          },
          assigns
        )
    }
  end

  describe "query_params/1" do
    test "keeps the page's query but drops the route's segments and an entry refusal" do
      params = %{
        "username" => "host",
        "slug" => "chat",
        "embed" => "1",
        "timezone" => "Etc/UTC",
        "refused" => "invalid-type"
      }

      assert PathHandlers.query_params(params) == %{"embed" => "1", "timezone" => "Etc/UTC"}
    end
  end

  describe "a demo page's chosen theme" do
    test "rides along a locale switch when it is not the organiser's own" do
      assert PathHandlers.build_path_with_locale(demo_socket(%{theme_id: "3"}), "de") ==
               "/demo-page?locale=de&theme=3"
    end

    test "adds nothing on the organiser's own theme" do
      assert PathHandlers.build_path_with_locale(demo_socket(%{theme_id: "1"}), "de") ==
               "/demo-page?locale=de"
    end

    # Issue #84: on an ordinary page a bare ?theme= must not survive a locale switch.
    test "is never carried by a page that is not a demo" do
      socket = demo_socket(%{theme_id: "3", demo_theme_switcher: false})
      assert PathHandlers.build_path_with_locale(socket, "de") == "/demo-page?locale=de"
      assert PathHandlers.demo_theme_param(socket.assigns) == %{}
    end
  end

  describe "current_base_path/1 and with_query/2" do
    test "name the route's step and append a query only when there is one" do
      assert PathHandlers.current_base_path(%{
               username_context: "johndoe",
               live_action: :schedule,
               duration: "30min"
             }) == "/johndoe/30-minutes"

      assert PathHandlers.current_base_path(%{}) == "/"
      assert PathHandlers.with_query("/johndoe", %{}) == "/johndoe"
      assert PathHandlers.with_query("/johndoe", %{"theme" => "2"}) == "/johndoe?theme=2"
    end
  end
end
