defmodule TymeslotWeb.Themes.Shared.InfoHandlersJourneyTest do
  @moduledoc """
  The shared flow on a journey of a theme's own, whose moments have their
  own names rather than the classic steps'.

  A calendar sync drops the time the visitor chose only while they have not
  moved past the moment that collects it. A `/book` deep link whose meeting
  type has questions still to answer goes to the moment that asks them. And
  the page names the moment its route opens on before that moment is
  entered. No organiser is resolved here, so the refetch a sync asks for is
  a no-op and the deep link looks no meeting type up.
  """
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :unit

  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine
  alias TymeslotWeb.Themes.Shared.InfoHandlers
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged
  alias TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry
  alias TymeslotWeb.Themes.Shared.SchedulingInit

  @own_journey %Journey{
    navigator: nil,
    outcomes: %{},
    moments: [
      %Moment{key: :offer, collects: [:meeting_type], component: nil, defaults: []},
      %Moment{key: :when, collects: [:slot], component: nil, defaults: []},
      %Moment{key: :ask, collects: [:answers], component: nil, defaults: []},
      %Moment{key: :you, collects: [:attendee], component: nil, defaults: []}
    ]
  }

  # A journey that asks the questions on the attendee's own moment.
  @asks_beside_attendee %Journey{
    navigator: nil,
    outcomes: %{},
    moments: [
      %Moment{key: :now, collects: [:meeting_type, :slot], component: nil, defaults: []},
      %Moment{key: :you, collects: [:answers, :attendee], component: nil, defaults: []}
    ]
  }

  @question %{
    "id" => "cf-company",
    "type" => "short_text",
    "label" => "Company",
    "required" => true,
    "position" => 0
  }

  describe "a calendar sync" do
    defp synced(current_state) do
      socket = %Socket{
        assigns: %{
          __changed__: %{},
          journey: @own_journey,
          current_state: current_state,
          selected_date: "2027-03-10",
          selected_time: "9:00 AM",
          available_slots: ["9:00 AM"],
          week_slots: nil
        }
      }

      {:noreply, socket} = InfoHandlers.handle_calendar_events_updated(socket)
      socket.assigns
    end

    test "drops the chosen time on the moment that collects it" do
      assert synced(:when).selected_time == nil
    end

    test "keeps the chosen time once the visitor has moved past that moment" do
      assert synced(:you).selected_time == "9:00 AM"
    end
  end

  describe "a /book deep link with a question still to answer" do
    # The attendee's moment entered from a link carrying the day and the time,
    # for a meeting type with one required question nobody has answered.
    defp deep_linked(journey) do
      meeting_type = %MeetingTypeSchema{
        id: 1,
        name: "Quick Chat",
        slug: "quick-chat",
        duration_minutes: 30,
        is_active: true,
        custom_fields: [@question]
      }

      socket = %Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          journey: journey,
          current_state: :you,
          username_context: nil,
          organizer_user_id: nil,
          reschedule_meeting_uid: nil,
          meeting_type_pinned: false,
          meeting_type: meeting_type,
          selected_date: "2027-03-10",
          selected_time: "9:00 AM",
          engine: QEngine.init([@question])
        }
      }

      StepEntry.handle_booking_entry(socket, %{}).assigns
    end

    test "goes to the moment that asks the questions, whatever it is called" do
      assert deep_linked(@own_journey).current_state == :ask
    end

    test "stays on a moment that asks the questions itself" do
      assert deep_linked(@asks_beside_attendee).current_state == :you
    end
  end

  describe "the page before its first moment is entered" do
    test "names the moment the route opens on" do
      socket = %Socket{
        assigns: %{
          __changed__: %{},
          live_action: :booking,
          journey: %{@own_journey | navigator: Paged}
        }
      }

      assert SchedulingInit.assign_theme_state(socket).assigns.current_state == :you
    end
  end
end
