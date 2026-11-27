defmodule Tymeslot.Bookings.RedirectParamsTest do
  @moduledoc """
  The address a new booking sends its booker to, and the `data` an embed's
  `onSuccess` callback is handed. Pure, so built from plain structs here.

  The one rule that matters most is the negative one: the meeting's `uid`
  opens its cancel and reschedule pages, so it must never reach either.
  """

  use ExUnit.Case, async: true

  @moduletag :bookings

  alias Tymeslot.Bookings.RedirectParams
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @secret_uid "uid-secret-bearer-token"

  defp meeting_type(attrs \\ []) do
    struct!(
      %MeetingTypeSchema{
        id: 42,
        name: "Discovery Call",
        redirect_url: "https://example.com/thanks",
        redirect_pass_details: true
      },
      attrs
    )
  end

  defp meeting(attrs \\ []) do
    struct!(
      %MeetingSchema{
        uid: @secret_uid,
        calendar_uid: "cal-uid-123",
        start_time: ~U[2025-02-06 14:00:00Z],
        end_time: ~U[2025-02-06 14:30:00Z],
        organizer_name: "Olivia Organiser",
        attendee_timezone: "Europe/Berlin"
      },
      attrs
    )
  end

  defp booker(attrs \\ %{}) do
    Map.merge(
      %{name: "Ada Lovelace", email: "ada@example.com", timezone: "Europe/Berlin"},
      attrs
    )
  end

  defp query(%{redirect_url: url}),
    do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  describe "with details passed off" do
    test "the address is the one the host saved, unchanged" do
      result =
        RedirectParams.build(
          meeting_type(redirect_pass_details: false, redirect_url: "https://example.com/t?x=1"),
          meeting(),
          booker()
        )

      assert result.redirect_url == "https://example.com/t?x=1"
    end

    test "data carries the event's facts and nothing personal" do
      %{data: data} =
        RedirectParams.build(meeting_type(redirect_pass_details: false), meeting(), booker())

      assert data == %{
               eventTypeName: "Discovery Call",
               eventTypeUuid: "42",
               eventStartTime: "2025-02-06T15:00:00+01:00",
               eventEndTime: "2025-02-06T15:30:00+01:00",
               assignedTo: "Olivia Organiser"
             }
    end
  end

  describe "with details passed on" do
    test "appends every parameter, in the invitee's time zone" do
      result =
        RedirectParams.build(
          meeting_type(),
          meeting(),
          booker(%{utm: %{utm_source: "linkedin", utm_medium: "social", utm_campaign: "spring"}})
        )

      assert query(result) == %{
               "event_type_name" => "Discovery Call",
               "event_type_uuid" => "42",
               "event_start_time" => "2025-02-06T15:00:00+01:00",
               "event_end_time" => "2025-02-06T15:30:00+01:00",
               "assigned_to" => "Olivia Organiser",
               "invitee_uuid" => "cal-uid-123",
               "invitee_email" => "ada@example.com",
               "invitee_full_name" => "Ada Lovelace",
               "invitee_first_name" => "Ada",
               "invitee_last_name" => "Lovelace",
               "utm_source" => "linkedin",
               "utm_medium" => "social",
               "utm_campaign" => "spring"
             }
    end

    test "values are form-encoded" do
      %{redirect_url: url} =
        RedirectParams.build(
          meeting_type(name: "Q&A / Intro"),
          meeting(),
          booker(%{name: "Zoë O'Brien", email: "zoe+test@example.com"})
        )

      assert url =~ "event_type_name=Q%26A+%2F+Intro"
      assert url =~ "invitee_email=zoe%2Btest%40example.com"
      assert url =~ "invitee_first_name=Zo%C3%AB"
    end

    test "keeps the address's own query and fragment, dropping only keys it sets" do
      %{redirect_url: url} =
        RedirectParams.build(
          meeting_type(redirect_url: "https://example.com/t?lang=de&utm_source=old#done"),
          meeting(),
          booker(%{utm: %{utm_source: "new"}})
        )

      uri = URI.parse(url)
      assert String.starts_with?(uri.query, "lang=de&")
      assert uri.fragment == "done"

      assert uri.query |> URI.query_decoder() |> Enum.filter(&(elem(&1, 0) == "utm_source")) ==
               [{"utm_source", "new"}]
    end

    test "leaves out empty and missing values" do
      result =
        RedirectParams.build(
          meeting_type(),
          meeting(organizer_name: nil),
          booker(%{email: "  ", utm: %{utm_source: "", utm_term: nil}})
        )

      query = query(result)
      refute Map.has_key?(query, "assigned_to")
      refute Map.has_key?(query, "invitee_email")
      refute Map.has_key?(query, "utm_source")
      refute Map.has_key?(query, "utm_term")
      refute Map.has_key?(result.data, :assignedTo)
      refute Map.has_key?(result.data, :inviteeEmail)
    end

    test "a one-word name is a first name only" do
      result = RedirectParams.build(meeting_type(), meeting(), booker(%{name: "Cher"}))

      assert query(result)["invitee_first_name"] == "Cher"
      refute Map.has_key?(query(result), "invitee_last_name")
      refute Map.has_key?(result.data, :inviteeLastName)
    end

    test "a name splits on its first whitespace" do
      result =
        RedirectParams.build(meeting_type(), meeting(), booker(%{name: "  Ada  Lovelace King "}))

      assert query(result)["invitee_full_name"] == "Ada  Lovelace King"
      assert query(result)["invitee_first_name"] == "Ada"
      assert query(result)["invitee_last_name"] == "Lovelace King"
    end

    test "data carries the personal details camel-cased" do
      %{data: data} =
        RedirectParams.build(
          meeting_type(),
          meeting(),
          booker(%{utm: %{utm_source: "x", utm_content: "c", utm_term: "t"}})
        )

      assert data.appointmentId == "cal-uid-123"
      assert data.inviteeUuid == "cal-uid-123"
      assert data.inviteeEmail == "ada@example.com"
      assert data.inviteeFullName == "Ada Lovelace"
      assert data.inviteeFirstName == "Ada"
      assert data.inviteeLastName == "Lovelace"
      assert data.utmSource == "x"
      assert data.utmContent == "c"
      assert data.utmTerm == "t"
      refute Map.has_key?(data, :utmMedium)
    end

    test "UTM tags under string keys are read as well" do
      result =
        RedirectParams.build(meeting_type(), meeting(), booker(%{utm: %{"utm_source" => "s"}}))

      assert query(result)["utm_source"] == "s"
    end
  end

  describe "the meeting's uid" do
    test "never appears in the address or the data" do
      for pass? <- [true, false] do
        result =
          RedirectParams.build(meeting_type(redirect_pass_details: pass?), meeting(), booker())

        refute result.redirect_url =~ @secret_uid
        refute inspect(result.data) =~ @secret_uid
      end
    end

    test "a seat is named by its own id, never the shared slot's" do
      # A seat view (`SeatView`) carries the seat's id as its `calendar_uid`.
      seat =
        meeting(
          calendar_uid: "seat-7",
          seat: %{participant_id: "seat-7", seats_taken: 2, previous: nil}
        )

      result = RedirectParams.build(meeting_type(), seat, booker())

      assert query(result)["invitee_uuid"] == "seat-7"
      assert result.data.inviteeUuid == "seat-7"
      assert result.data.appointmentId == "seat-7"
      refute inspect(result) =~ @secret_uid
    end
  end

  describe "answers" do
    @snapshot [
      %{"id" => "q1", "type" => "short_text", "label" => "Company"},
      %{"id" => "n1", "type" => "note", "label" => "Read this", "body" => "Policy"},
      %{
        "id" => "q2",
        "type" => "multi_select",
        "label" => "Topics",
        "options" => [
          %{"key" => "a", "label" => "Pricing"},
          %{"key" => "b", "label" => "Support"}
        ]
      },
      %{"id" => "q3", "type" => "yes_no", "label" => "Existing customer?"},
      %{"id" => "q4", "type" => "file", "label" => "Upload"},
      %{
        "id" => "q5",
        "type" => "single_select",
        "label" => "Size",
        "options" => [%{"key" => "s", "label" => "Small team"}]
      },
      %{"id" => "q6", "type" => "short_text", "label" => "Left blank"},
      %{"id" => "q7", "type" => "number", "label" => "Seats"},
      %{"id" => "q8", "type" => "yes_no", "label" => "Newsletter?"}
    ]

    @answers %{
      "q1" => "Acme",
      "n1" => %{"confirmed" => true},
      "q2" => ["a", "b"],
      "q3" => true,
      "q4" => "upload-ref",
      "q5" => "s",
      "q7" => 12,
      "q8" => false
    }

    defp with_answers(pass? \\ true) do
      RedirectParams.build(
        meeting_type(redirect_pass_details: pass?),
        meeting(),
        booker(%{custom_fields_snapshot: @snapshot, custom_field_answers: @answers})
      )
    end

    test "are numbered by question, skipping notes and non-textual answers" do
      query = query(with_answers())

      assert query["answer_1"] == "Acme"
      assert query["answer_2"] == "Pricing, Support"
      assert query["answer_3"] == "Yes"
      refute Map.has_key?(query, "answer_4")
      assert query["answer_5"] == "Small team"
      refute Map.has_key?(query, "answer_6")
      assert query["answer_7"] == "12"
      assert query["answer_8"] == "No"
      refute Map.has_key?(query, "answer_9")
    end

    test "data lists them by position, blank where there is nothing to pass" do
      assert with_answers().data.answers ==
               ["Acme", "Pricing, Support", "Yes", "", "Small team", "", "12", "No"]
    end

    test "are left out entirely with details passed off" do
      result = with_answers(false)

      refute result.redirect_url =~ "answer_"
      refute Map.has_key?(result.data, :answers)
    end

    test "the address carries at most ten" do
      snapshot = for n <- 1..12, do: %{"id" => "q#{n}", "type" => "short_text"}
      answers = Map.new(1..12, &{"q#{&1}", "a#{&1}"})

      result =
        RedirectParams.build(
          meeting_type(),
          meeting(),
          booker(%{custom_fields_snapshot: snapshot, custom_field_answers: answers})
        )

      assert query(result)["answer_10"] == "a10"
      refute Map.has_key?(query(result), "answer_11")
    end
  end

  describe "without a redirect address" do
    test "the address is nil, and data is still built" do
      result = RedirectParams.build(meeting_type(redirect_url: nil), meeting(), booker())

      assert result.redirect_url == nil
      assert result.data.eventTypeName == "Discovery Call"
      assert result.data.inviteeEmail == "ada@example.com"
    end

    test "a blank address counts as none" do
      assert RedirectParams.build(meeting_type(redirect_url: "  "), meeting(), booker()).redirect_url ==
               nil
    end
  end

  describe "time zones" do
    test "an unknown time zone falls back to UTC" do
      result =
        RedirectParams.build(meeting_type(), meeting(), booker(%{timezone: "Mars/Olympus"}))

      assert result.data.eventStartTime == "2025-02-06T14:00:00Z"
    end

    test "a zone west of UTC carries a negative offset" do
      result =
        RedirectParams.build(meeting_type(), meeting(), booker(%{timezone: "America/New_York"}))

      assert result.data.eventStartTime == "2025-02-06T09:00:00-05:00"
    end
  end

  test "a plain-map meeting type (a demo organiser's) builds without an id" do
    result =
      RedirectParams.build(%{name: "Demo", redirect_url: nil}, meeting(), booker())

    assert result.data.eventTypeName == "Demo"
    refute Map.has_key?(result.data, :eventTypeUuid)
  end
end
