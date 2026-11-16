defmodule Tymeslot.CalendarGrid.MeetingParamsTest do
  @moduledoc """
  A Tymeslot meeting the calendar's side panel books: the drafted event
  as `CreateParams` cast it, plus the guest's name, the language and the
  reminder emails, turned into what `EventCreation.run_create_ad_hoc_meeting/1`
  takes, or refused with the field that failed. Also the budget each
  meeting spends.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :unit

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.MeetingParams

  @fields %{
    "guest_name" => "  Ada Lovelace ",
    "locale" => "fr",
    "reminders" => ["", "1_days", "30_minutes"]
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
                reminders: [%{value: 30, unit: "minutes"}, %{value: 1, unit: "days"}]
              }}
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

  test "a reminder that is not one of the choices is refused" do
    assert MeetingParams.build(create(), %{@fields | "reminders" => ["2_weeks"]}, 42) ==
             {:error, :reminders, :invalid}
  end

  test "ticking no reminder means no reminder email" do
    assert {:ok, %{reminders: []}} =
             MeetingParams.build(create(), %{@fields | "reminders" => [""]}, 42)
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
