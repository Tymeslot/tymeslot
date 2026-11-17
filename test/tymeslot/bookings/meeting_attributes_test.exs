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

  describe "build_series/2" do
    setup do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      meeting_type = insert(:meeting_type, user: user, description: "Course session")

      params =
        BuildParams.new(%{
          duration_minutes: 30,
          form_data: %{"name" => "Attendee", "email" => "attendee@example.com"},
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id,
          user_timezone: "UTC"
        })

      %{user: user, params: params}
    end

    defp sessions(count) do
      first = DateTime.truncate(DateTime.add(DateTime.utc_now(), 2, :day), :second)

      for position <- 1..count do
        start = DateTime.add(first, 7 * (position - 1), :day)

        %{
          meeting_uid: "session-#{position}",
          start_datetime: start,
          end_datetime: DateTime.add(start, 30, :minute),
          series_position: position
        }
      end
    end

    # The queries this process runs while `fun` does.
    defp queries(fun) do
      test_pid = self()
      handler_id = "meeting-attributes-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, %{source: source}, _config ->
          if self() == test_pid, do: send(test_pid, {:query, source})
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

      collect_queries([])
    end

    defp collect_queries(acc) do
      receive do
        {:query, source} -> collect_queries([source | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "each session carries its own uid, times, position and links, and the rest is shared",
         %{params: params} do
      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      sessions = sessions(3)
      built = MeetingAttributes.build_series(params, sessions)

      assert Enum.map(built, &{&1.uid, &1.start_time, &1.series_position}) ==
               Enum.map(sessions, &{&1.meeting_uid, &1.start_datetime, &1.series_position})

      assert Enum.map(built, & &1.end_time) == Enum.map(sessions, & &1.end_datetime)
      assert built |> Enum.map(& &1.cancel_url) |> Enum.uniq() |> length() == 3

      # Each is exactly what `build/1` gives that session alone.
      for {attrs, session} <- Enum.zip(built, sessions) do
        assert attrs == MeetingAttributes.build(struct!(params, session))
      end
    end

    test "the organiser, type and integrations are read once, however many sessions",
         %{params: params} do
      # One booking integration lookup for the whole series.
      expect(Tymeslot.CalendarMock, :get_booking_integration_info, 1, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      many =
        queries(fn -> assert length(MeetingAttributes.build_series(params, sessions(6))) == 6 end)

      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      one = queries(fn -> MeetingAttributes.build_series(params, sessions(1)) end)

      assert many != []
      assert many == one
    end

    test "a series held for approval gives every session the first one's clock",
         %{user: user, params: params} do
      stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _client ->
        {:ok, %{integration_id: 1, calendar_path: "primary"}}
      end)

      gated = insert(:meeting_type, user: user, requires_approval: true)
      built = MeetingAttributes.build_series(%{params | meeting_type_id: gated.id}, sessions(3))

      assert Enum.all?(built, &(&1.status == :awaiting_approval))

      assert [_one_clock] =
               built
               |> Enum.map(&{&1.approval_requested_at, &1.approval_deadline_at})
               |> Enum.uniq()

      # The deadline falls after the request and no later than the first session.
      [first | _rest] = built
      assert %DateTime{} = first.approval_deadline_at
      assert DateTime.compare(first.approval_deadline_at, first.approval_requested_at) == :gt
      assert DateTime.compare(first.approval_deadline_at, first.start_time) != :gt
    end
  end
end
