defmodule Tymeslot.Bookings.MeetingAttributesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :bookings

  import Tymeslot.Factory
  import Mox

  setup :verify_on_exit!

  alias Tymeslot.Bookings.BuildParams
  alias Tymeslot.Bookings.MeetingAttributes

  describe "build/1 description" do
    test "takes description from the meeting type, not the attendee's message" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      meeting_type = insert(:meeting_type, user: user, description: "Quarterly review")

      params = %{
        meeting_uid: "meeting-uid",
        start_datetime: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_datetime: DateTime.add(DateTime.utc_now(), 5400, :second),
        duration_minutes: 30,
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => "Please bring slides."
        },
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        user_timezone: "UTC"
      }

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      attrs = MeetingAttributes.build(BuildParams.new(params))

      assert attrs.description == "Quarterly review"
      assert attrs.attendee_message == "Please bring slides."
    end

    test "defaults description to empty string when no meeting type is supplied" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      params = %{
        meeting_uid: "meeting-uid",
        start_datetime: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_datetime: DateTime.add(DateTime.utc_now(), 5400, :second),
        duration_minutes: 30,
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => "Hi!"
        },
        organizer_user_id: user.id,
        meeting_type_id: nil,
        user_timezone: "UTC"
      }

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      attrs = MeetingAttributes.build(BuildParams.new(params))

      assert attrs.description == ""
      assert attrs.attendee_message == "Hi!"
    end
  end

  describe "build/1 title" do
    setup do
      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      :ok
    end

    defp build_title_attrs(organizer_locale) do
      user = insert(:user, locale: organizer_locale)
      _profile = insert(:profile, user: user)
      meeting_type = insert(:meeting_type, user: user, name: "IRIS Demo")

      params = %{
        meeting_uid: "meeting-uid",
        start_datetime: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_datetime: DateTime.add(DateTime.utc_now(), 5400, :second),
        duration_minutes: 30,
        form_data: %{"name" => "Jane Doe", "email" => "jane@example.com"},
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        user_timezone: "UTC",
        attendee_locale: "en"
      }

      MeetingAttributes.build(BuildParams.new(params))
    end

    test "renders the title in the organiser's language, not the attendee's" do
      attrs = build_title_attrs("de")

      assert attrs.title == "IRIS Demo mit Jane Doe"
      assert attrs.summary == "IRIS Demo mit Jane Doe"
    end

    test "keeps the English title for an English-speaking organiser" do
      assert build_title_attrs("en").title == "IRIS Demo with Jane Doe"
    end
  end

  describe "build/1 reminders snapshot" do
    test "uses meeting type reminder config when present" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          reminder_config: [%{value: 10, unit: "minutes"}, %{value: 1, unit: "hours"}]
        )

      params = %{
        meeting_uid: "meeting-uid",
        start_datetime: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_datetime: DateTime.add(DateTime.utc_now(), 5400, :second),
        duration_minutes: 30,
        form_data: %{"name" => "Attendee", "email" => "attendee@example.com", "message" => ""},
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        user_timezone: "UTC"
      }

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      attrs = MeetingAttributes.build(BuildParams.new(params))

      assert attrs.reminders == [%{value: 10, unit: "minutes"}, %{value: 1, unit: "hours"}]
    end

    test "respects explicit empty reminder config" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          reminder_config: []
        )

      params = %{
        meeting_uid: "meeting-uid",
        start_datetime: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_datetime: DateTime.add(DateTime.utc_now(), 5400, :second),
        duration_minutes: 30,
        form_data: %{"name" => "Attendee", "email" => "attendee@example.com", "message" => ""},
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        user_timezone: "UTC"
      }

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      attrs = MeetingAttributes.build(BuildParams.new(params))

      assert attrs.reminders == []
    end
  end
end
