defmodule Tymeslot.CalendarGrid.MeetingParamsTest do
  @moduledoc """
  A Tymeslot meeting the calendar's side panel books: the drafted event
  as `CreateParams` cast it, plus the guest's name, the language and the
  reminder emails, whether it has a main participant and where it takes
  place, turned into what `EventCreation.run_create_ad_hoc_meeting/1`
  takes, or refused with the field that failed. Also the budget each
  meeting spends.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :unit

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.MeetingParams
  alias Tymeslot.Meetings.Guests

  @fields %{
    "guest_name" => "  Ada Lovelace ",
    "locale" => "fr",
    "reminders" => [%{value: 30, unit: "minutes"}, %{value: 1, unit: "days"}]
  }

  defp create(attrs \\ %{}) do
    struct!(
      CreateParams,
      Map.merge(
        %{
          integration_id: 7,
          calendar_id: "work",
          title: "Roadmap review",
          start_at: ~U[2026-10-15 12:00:00Z],
          end_at: ~U[2026-10-15 13:00:00Z],
          timezone: "Europe/London",
          guests: ["ada@example.com", "grace@example.com"],
          description: "Bring the Q3 numbers.",
          video_integration_id: 3
        },
        attrs
      )
    )
  end

  test "the first guest is the one the meeting is with; the others are its guests" do
    assert MeetingParams.build(create(), @fields, 42) ==
             {:ok,
              %{
                title: "Roadmap review",
                start_time: ~U[2026-10-15 12:00:00Z],
                end_time: ~U[2026-10-15 13:00:00Z],
                attendee_name: "Ada Lovelace",
                attendee_email: "ada@example.com",
                attendee_timezone: "Europe/London",
                organizer_user_id: 42,
                calendar_integration_id: 7,
                calendar_id: "work",
                video_integration_id: 3,
                organizer_note: "Bring the Q3 numbers.",
                attendee_locale: "fr",
                guest_emails: ["grace@example.com"],
                reminders: [%{value: 30, unit: "minutes"}, %{value: 1, unit: "days"}],
                location: nil
              }}
  end

  describe "without a main participant" do
    @managed Map.merge(@fields, %{"main_participant" => false, "title" => "Roadmap review"})

    test "every guest is an equal guest of a meeting the host manages" do
      assert {:ok, params} = MeetingParams.build(create(), @managed, 42)

      assert %{
               managed_by_host: true,
               guest_emails: ["ada@example.com", "grace@example.com"],
               title: "Roadmap review"
             } = params

      refute Map.has_key?(params, :attendee_name)
      refute Map.has_key?(params, :attendee_email)
    end

    test "a meeting with no title of its own is refused" do
      assert MeetingParams.build(create(), %{@managed | "title" => " "}, 42) ==
               {:error, :title, :blank}
    end

    test "the guests count against the guests' own limit" do
      guests = Enum.map(1..(Guests.max_guests() + 1), &"guest#{&1}@example.com")

      assert MeetingParams.build(create(%{guests: guests}), @managed, 42) ==
               {:error, :guests, :too_many_guests}
    end
  end

  describe "location" do
    test "a place typed in is trimmed; one left blank is none" do
      typed = Map.put(%{@fields | "guest_name" => "Ada"}, "location_choice", "custom")

      assert {:ok, %{location: {:custom, "Room 4"}}} =
               MeetingParams.build(create(), Map.put(typed, "location_custom", " Room 4 "), 42)

      assert {:ok, %{location: nil}} =
               MeetingParams.build(create(), Map.put(typed, "location_custom", "  "), 42)
    end

    test "a place typed in is sanitised as plain text" do
      typed = Map.merge(@fields, %{"guest_name" => "Ada", "location_choice" => "custom"})

      assert {:ok, %{location: {:custom, "Room 4"}}} =
               MeetingParams.build(create(), Map.put(typed, "location_custom", "Room\x00 4"), 42)

      assert MeetingParams.build(
               create(),
               Map.put(typed, "location_custom", <<0xFF, ?R, ?o, ?o, ?m>>),
               42
             ) == {:error, :location, :unsafe}
    end

    test "a place longer than a meeting takes is refused" do
      fields =
        Map.merge(@fields, %{
          "location_choice" => "custom",
          "location_custom" => String.duplicate("a", 501)
        })

      assert MeetingParams.build(create(), fields, 42) == {:error, :location, :too_long}
    end

    # A saved location of someone else's is looked up and refused in
    # `CalendarSurfaceMeetingOptionsTest`; these need no database.
    test "a choice that names no saved location is refused" do
      for choice <- ["venue:abc", "venue:", "video:3"] do
        assert MeetingParams.build(create(), Map.put(@fields, "location_choice", choice), 42) ==
                 {:error, :location, :invalid}
      end
    end
  end

  test "an all-day draft is refused: a meeting has a start and an end time" do
    all_day = create(%{all_day: true, start_at: ~D[2026-10-15], end_at: ~D[2026-10-16]})

    assert MeetingParams.build(all_day, @fields, 42) == {:error, :all_day, :timed_only}
  end

  test "a draft with no guest is refused" do
    assert MeetingParams.build(create(%{guests: []}), @fields, 42) == {:error, :guests, :none}
  end

  test "more guests than a meeting takes are refused" do
    guests = for n <- 1..(MeetingParams.max_guests() + 1), do: "guest#{n}@example.com"

    assert MeetingParams.build(create(%{guests: guests}), @fields, 42) ==
             {:error, :guests, :too_many}

    assert {:ok, _params} =
             MeetingParams.build(create(%{guests: Enum.drop(guests, 1)}), @fields, 42)
  end

  test "a blank or missing guest name is refused" do
    for name <- ["   ", nil] do
      assert MeetingParams.build(create(), %{@fields | "guest_name" => name}, 42) ==
               {:error, :guest_name, :blank}
    end
  end

  test "a language Tymeslot does not offer is refused; none leaves it to the default" do
    assert MeetingParams.build(create(), %{@fields | "locale" => "xx"}, 42) ==
             {:error, :locale, :invalid}

    assert {:ok, %{attendee_locale: nil}} =
             MeetingParams.build(create(), %{@fields | "locale" => ""}, 42)
  end

  test "any lead time a meeting type could have is taken, string keys and all" do
    reminders = [%{"value" => "2", "unit" => "weeks"}]

    assert MeetingParams.build(create(), %{@fields | "reminders" => reminders}, 42) ==
             {:error, :reminders, :invalid}

    reminders = [%{"value" => 45, "unit" => "minutes"}, %{value: 2, unit: "days"}]

    assert {:ok, %{reminders: [%{value: 45, unit: "minutes"}, %{value: 2, unit: "days"}]}} =
             MeetingParams.build(create(), %{@fields | "reminders" => reminders}, 42)
  end

  test "reminders a meeting type could not have are refused" do
    for reminders <- [
          [%{value: 0, unit: "minutes"}],
          [%{value: 30, unit: "minutes"}, %{value: 30, unit: "minutes"}],
          Enum.map(1..4, &%{value: &1, unit: "hours"}),
          ["30_minutes"]
        ] do
      assert MeetingParams.build(create(), %{@fields | "reminders" => reminders}, 42) ==
               {:error, :reminders, :invalid}
    end
  end

  test "no reminder means no reminder email" do
    assert {:ok, %{reminders: []}} =
             MeetingParams.build(create(), %{@fields | "reminders" => []}, 42)
  end

  test "a note past the meeting's own limit is refused" do
    assert MeetingParams.build(create(%{description: String.duplicate("a", 2001)}), @fields, 42) ==
             {:error, :note, :too_long}

    assert {:ok, %{organizer_note: note}} =
             MeetingParams.build(create(%{description: String.duplicate("a", 2000)}), @fields, 42)

    assert String.length(note) == 2000
  end

  test "rate_limit/1 lets 10 meetings through, then refuses" do
    user_id = System.unique_integer([:positive])

    for _n <- 1..10, do: assert(MeetingParams.rate_limit(user_id) == :ok)

    assert {:error, :rate_limited, _message} = MeetingParams.rate_limit(user_id)
  end
end
