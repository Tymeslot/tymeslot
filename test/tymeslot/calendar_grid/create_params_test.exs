defmodule Tymeslot.CalendarGrid.CreateParamsTest do
  @moduledoc """
  The server's own check of a create the calendar asks for: every field
  the browser sends is checked again before anything is written, and the
  first that fails is named with its reason.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.CreateParams

  @zone "Europe/London"

  setup do
    user = insert(:user, email: "organiser@example.com")

    google = %{
      id: 1,
      user_id: user.id,
      provider: "google",
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true},
        %{"id" => "old", "name" => "Old", "selected" => false},
        %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
      ]
    }

    feed = %{
      id: 2,
      user_id: user.id,
      provider: "ics_url",
      calendar_list: [%{"id" => "feed", "name" => "Holidays", "selected" => true}]
    }

    exchange = %{
      id: 3,
      user_id: user.id,
      provider: "exchange",
      calendar_list: [%{"id" => "inbox", "name" => "Calendar", "selected" => true}]
    }

    someone_elses = %{
      id: 4,
      user_id: user.id + 1,
      provider: "google",
      calendar_list: [%{"id" => "theirs", "name" => "Theirs", "selected" => true}]
    }

    %{user: user, integrations: [google, feed, exchange, someone_elses]}
  end

  @lunch %{
    "title" => "Lunch",
    "start" => "2026-10-15T13:00",
    "end" => "2026-10-15T14:00",
    "all_day" => false,
    "calendar" => "1:work",
    "free" => false,
    "guests" => []
  }

  defp cast(context, changes \\ %{}),
    do:
      CreateParams.cast(context.user.id, context.integrations, Map.merge(@lunch, changes), @zone)

  test "a timed create resolves the organiser's wall clock to UTC", context do
    assert {:ok, %CreateParams{} = params} = cast(context)

    assert params.title == "Lunch"
    assert params.integration_id == 1
    assert params.calendar_id == "work"
    assert params.start_at == ~U[2026-10-15 12:00:00Z]
    assert params.end_at == ~U[2026-10-15 13:00:00Z]
    assert params.all_day == false
    assert params.free == false
    assert params.guests == []
    assert params.timezone == @zone
  end

  test "a free create is written as transparent", context do
    assert {:ok, %CreateParams{free: true} = params} = cast(context, %{"free" => true})
    assert CreateParams.to_payload(params).creating.transparency == "transparent"
  end

  test "a busy create is written as opaque", context do
    {:ok, params} = cast(context)
    assert CreateParams.to_payload(params).creating.transparency == "opaque"
  end

  describe "the calendar" do
    test "must be a key it can read", context do
      assert {:error, :calendar, :invalid} = cast(context, %{"calendar" => "work"})
      assert {:error, :calendar, :invalid} = cast(context, %{"calendar" => "x:work"})
      assert {:error, :calendar, :invalid} = cast(context, %{"calendar" => "1:"})
      assert {:error, :calendar, :invalid} = cast(context, %{"calendar" => nil})
    end

    test "must be one of the organiser's own", context do
      assert {:error, :calendar, :not_found} = cast(context, %{"calendar" => "99:work"})
      assert {:error, :calendar, :not_found} = cast(context, %{"calendar" => "4:theirs"})
    end

    test "must be synced", context do
      assert {:error, :calendar, :not_found} = cast(context, %{"calendar" => "1:old"})
      assert {:error, :calendar, :not_found} = cast(context, %{"calendar" => "1:nowhere"})
    end

    test "must take writes", context do
      assert {:error, :calendar, :read_only} = cast(context, %{"calendar" => "1:shared"})
      assert {:error, :calendar, :read_only} = cast(context, %{"calendar" => "2:feed"})
    end
  end

  describe "the timing" do
    test "must be readable", context do
      assert {:error, :start, :invalid} = cast(context, %{"start" => "tomorrow"})
      assert {:error, :start, :invalid} = cast(context, %{"start" => "2026-10-15T25:00"})
      assert {:error, :end, :invalid} = cast(context, %{"end" => "2026-10-15"})
      assert {:error, :start, :invalid} = cast(context, %{"start" => nil})
    end

    test "must end after it starts", context do
      assert {:error, :end, :before_start} = cast(context, %{"end" => "2026-10-15T12:00"})
      assert {:error, :end, :before_start} = cast(context, %{"end" => "2026-10-15T13:00"})
    end

    test "may last a week, and no longer", context do
      assert {:ok, _params} = cast(context, %{"end" => "2026-10-22T13:00"})

      assert {:error, :end, :longer_than_a_week} =
               cast(context, %{"end" => "2026-10-22T13:15"})
    end

    test "must start in the years the calendar shows", context do
      assert {:error, :start, :out_of_range} =
               cast(context, %{"start" => "1899-12-31T10:00", "end" => "1899-12-31T11:00"})
    end

    test "an all-day create keeps its dates, with the exclusive end", context do
      assert {:ok, params} =
               cast(context, %{"all_day" => true, "start" => "2026-10-16", "end" => "2026-10-18"})

      assert {params.all_day, params.start_at, params.end_at} ==
               {true, ~D[2026-10-16], ~D[2026-10-18]}
    end

    test "an all-day create lasts at least a day", context do
      assert {:error, :end, :before_start} =
               cast(context, %{"all_day" => true, "start" => "2026-10-16", "end" => "2026-10-16"})
    end

    test "an all-day create lasts at most a year", context do
      assert {:ok, _params} =
               cast(context, %{"all_day" => true, "start" => "2026-01-01", "end" => "2027-01-02"})

      assert {:error, :end, :longer_than_a_year} =
               cast(context, %{"all_day" => true, "start" => "2026-01-01", "end" => "2027-01-03"})
    end

    test "an all-day create takes dates, not times", context do
      assert {:error, :start, :invalid} = cast(context, %{"all_day" => true})
    end

    test "all day must be a boolean", context do
      assert {:error, :all_day, :invalid} = cast(context, %{"all_day" => "yes"})
    end
  end

  describe "the title" do
    test "is trimmed", context do
      assert {:ok, %{title: "Lunch with Anna"}} =
               cast(context, %{"title" => "  Lunch with Anna  "})
    end

    test "cannot be blank (the web layer names an untitled draft first)", context do
      assert {:error, :title, :blank} = cast(context, %{"title" => "   "})
      assert {:error, :title, :blank} = cast(context, %{"title" => nil})
    end

    test "loses its null bytes", context do
      assert {:ok, %{title: "Lunch with Anna"}} =
               cast(context, %{"title" => "Lunch\u0000 with Anna"})
    end

    test "may be 500 characters, and no more", context do
      assert {:ok, _params} = cast(context, %{"title" => String.duplicate("a", 500)})

      assert {:error, :title, :too_long} =
               cast(context, %{"title" => String.duplicate("a", 501)})
    end

    test "must be text", context do
      assert {:error, :title, :invalid} = cast(context, %{"title" => 42})
    end
  end

  describe "the place and notes" do
    test "are trimmed, lose their null bytes, and a blank one is none", context do
      assert {:ok, %{location: "Room 4"}} = cast(context, %{"location" => " Room\u0000 4 "})
      assert {:ok, %{location: nil}} = cast(context, %{"location" => "  "})

      assert {:ok, %{description: "Bring slides"}} =
               cast(context, %{"description" => "Bring slides"})
    end

    test "have length limits", context do
      assert {:error, :location, :too_long} =
               cast(context, %{"location" => String.duplicate("a", 1_001)})

      assert {:error, :description, :too_long} =
               cast(context, %{"description" => String.duplicate("a", 5_001)})
    end
  end

  describe "the guests" do
    test "are trimmed, lower-cased and merged", context do
      assert {:ok, %{guests: ["anna@example.com", "ben@example.com"]}} =
               cast(context, %{
                 "guests" => [" Anna@Example.com", "ben@example.com", "anna@example.com"]
               })
    end

    test "leave out the organiser's own address", context do
      assert {:ok, %{guests: ["anna@example.com"]}} =
               cast(context, %{"guests" => ["anna@example.com", "Organiser@Example.com"]})
    end

    test "must all be valid addresses", context do
      assert {:error, :guests, :invalid_email} =
               cast(context, %{"guests" => ["anna@example.com", "anna"]})

      assert {:error, :guests, :invalid_email} = cast(context, %{"guests" => [42]})
    end

    test "number at most 50", context do
      fifty = for n <- 1..50, do: "guest#{n}@example.com"

      assert {:ok, %{guests: guests}} = cast(context, %{"guests" => fifty})
      assert length(guests) == 50

      assert {:error, :guests, :too_many} =
               cast(context, %{"guests" => ["one-more@example.com" | fifty]})
    end

    test "a repeated address does not count twice towards the limit", context do
      fifty = for n <- 1..50, do: "guest#{n}@example.com"
      assert {:ok, _params} = cast(context, %{"guests" => fifty ++ ["GUEST1@example.com"]})
    end

    test "must be a list", context do
      assert {:error, :guests, :invalid} = cast(context, %{"guests" => "anna@example.com"})
    end
  end

  describe "the panel's fields" do
    test "reminders take popup or email and a lead time", context do
      assert {:ok, %{reminders: [%{method: :popup, minutes_before: 10}]}} =
               cast(context, %{"reminders" => [%{"method" => "popup", "minutes" => 10}]})

      assert {:error, :reminders, :invalid} =
               cast(context, %{"reminders" => [%{"method" => "sms", "minutes" => 10}]})

      assert {:error, :reminders, :invalid} =
               cast(context, %{"reminders" => [%{"method" => "email", "minutes" => -5}]})

      six = for minutes <- 1..6, do: %{"method" => "popup", "minutes" => minutes}
      assert {:error, :reminders, :too_many} = cast(context, %{"reminders" => six})
    end

    test "a repeat rule must be readable and the calendar must repeat events", context do
      assert {:ok, %{recurrence_rule: "FREQ=WEEKLY"}} =
               cast(context, %{"recurrence_rule" => "FREQ=WEEKLY"})

      assert {:error, :recurrence_rule, :invalid} =
               cast(context, %{"recurrence_rule" => "every so often"})

      assert {:error, :recurrence_rule, :not_repeatable} =
               cast(context, %{"calendar" => "3:inbox", "recurrence_rule" => "FREQ=WEEKLY"})
    end

    test "a video integration is the organiser's own, given as an id", context do
      video = insert(:video_integration, user: context.user)

      assert {:ok, %{video_integration_id: id}} =
               cast(context, %{"video_integration_id" => video.id})

      assert id == video.id

      assert {:ok, %{video_integration_id: ^id}} =
               cast(context, %{"video_integration_id" => to_string(video.id)})

      assert {:error, :video_integration_id, :invalid} =
               cast(context, %{"video_integration_id" => "seven"})
    end

    test "a video integration that does not exist is refused", context do
      assert {:error, :video_integration_id, :not_found} =
               cast(context, %{"video_integration_id" => 987_654_321})
    end

    test "another organiser's video integration is refused", context do
      theirs = insert(:video_integration, user: insert(:user))

      assert {:error, :video_integration_id, :not_found} =
               cast(context, %{"video_integration_id" => theirs.id})
    end
  end

  test "anything but a map is refused", context do
    assert {:error, :params, :invalid} =
             CreateParams.cast(context.user.id, context.integrations, "Lunch", @zone)
  end

  test "to_payload/1 gives the create everything it writes", context do
    {:ok, params} =
      cast(context, %{
        "location" => "Room 4",
        "guests" => ["anna@example.com"],
        "reminders" => [%{"method" => "email", "minutes" => 30}]
      })

    assert %{
             creating: %{
               title: "Lunch",
               integration_id: 1,
               calendar_id: "work",
               all_day: false,
               location: "Room 4",
               attendees: ["anna@example.com"],
               reminders: [%{method: :email, minutes_before: 30}],
               transparency: "opaque"
             },
             start_at: ~U[2026-10-15 12:00:00Z],
             end_at: ~U[2026-10-15 13:00:00Z],
             timezone: @zone
           } = CreateParams.to_payload(params)
  end

  describe "guests/2" do
    test "trims, lower-cases and drops the organiser's own address", %{user: user} do
      assert {:ok, ["ada@example.com"]} =
               CreateParams.guests(user.id, ["  Ada@Example.com ", "ORGANISER@example.com"])
    end

    test "refuses an invalid address and more than the limit", %{user: user} do
      assert {:error, :guests, :invalid_email} = CreateParams.guests(user.id, ["nope"])

      crowd = for n <- 1..(CreateParams.max_guests() + 1), do: "g#{n}@example.com"
      assert {:error, :guests, :too_many} = CreateParams.guests(user.id, crowd)
    end
  end
end
