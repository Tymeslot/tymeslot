defmodule TymeslotWeb.Themes.Shared.Journey.FactClearTest do
  @moduledoc """
  Forgetting a fact (`Fact.clear/1`) and the facts depending on it
  (`Runtime.clear/2`), which a transcript's "Edit" does. Each shipped fact is
  known on the assigns below before it is forgotten, so a `clear/1` that
  dropped the wrong assign would leave it known and fail here.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine
  alias TymeslotWeb.Themes.Shared.Journey.Facts.{Answers, Attendee, MeetingType, Slot}
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @question %{
    "id" => "cf-company",
    "type" => "short_text",
    "label" => "Company",
    "required" => true,
    "position" => 0
  }

  defp meeting_type do
    %MeetingTypeSchema{
      id: 1,
      name: "Quick Chat",
      slug: "quick-chat",
      duration_minutes: 30,
      is_active: true,
      custom_fields: []
    }
  end

  # A booking with every fact but the attendee known: a meeting type with one
  # answered question, a day and a time, and the token of the open attendee
  # moment.
  defp socket(changes \\ %{}) do
    engine = [@question] |> QEngine.init() |> QEngine.answer("cf-company", "Acme")

    assigns =
      Map.merge(
        %{
          __changed__: %{},
          meeting_types: [meeting_type()],
          meeting_type: meeting_type(),
          meeting_type_pinned: false,
          selected_duration: "quick-chat",
          duration: "quick-chat",
          selected_date: "2027-03-10",
          selected_time: "9:00 AM",
          available_slots: ["9:00 AM", "9:30 AM"],
          engine: engine,
          submission_token: "token-1",
          submission_processed: false
        },
        changes
      )

    %Socket{assigns: assigns}
  end

  describe "MeetingType.clear/1" do
    test "forgets the chosen meeting type" do
      assert MeetingType.known?(socket().assigns)

      cleared = MeetingType.clear(socket())

      refute MeetingType.known?(cleared.assigns)
      assert cleared.assigns.selected_duration == nil
      assert cleared.assigns.meeting_type == nil
    end

    test "keeps a pinned reschedule's meeting type" do
      pinned = socket(%{meeting_type_pinned: true})

      assert MeetingType.clear(pinned).assigns == pinned.assigns
    end
  end

  describe "Slot.clear/1" do
    test "forgets the time and keeps the day" do
      assert Slot.known?(socket().assigns)

      cleared = Slot.clear(socket())

      refute Slot.known?(cleared.assigns)
      assert cleared.assigns.selected_time == nil
      assert cleared.assigns.selected_date == "2027-03-10"
    end
  end

  describe "Answers.clear/1" do
    test "starts the same questions again from blank" do
      cleared = Answers.clear(socket())

      assert cleared.assigns.engine.answers == %{}
      assert cleared.assigns.engine.definitions == socket().assigns.engine.definitions
    end
  end

  describe "Attendee.clear/1" do
    test "drops the submission token" do
      cleared = Attendee.clear(socket())

      assert cleared.assigns.submission_token == nil
    end
  end

  describe "Runtime.clear/2" do
    test "forgets the slot and the attendee that depends on it, not the meeting type" do
      cleared = Runtime.clear(socket(), [:slot])

      assert cleared.assigns.selected_time == nil
      assert cleared.assigns.submission_token == nil
      assert cleared.assigns.selected_duration == "quick-chat"
      assert cleared.assigns.engine.answers == %{"cf-company" => "Acme"}
    end

    test "forgets everything that depends on the meeting type" do
      cleared = Runtime.clear(socket(), [:meeting_type])

      assert cleared.assigns.selected_duration == nil
      assert cleared.assigns.selected_time == nil
      assert cleared.assigns.engine.answers == %{}
      assert cleared.assigns.submission_token == nil
    end
  end
end
