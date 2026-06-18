defmodule Tymeslot.Bookings.CreateTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false
  @moduletag :bookings

  alias __MODULE__.MockCalendar
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo

  # Shared test setup helper
  defp setup_booking_test do
    user = insert(:user)
    _profile = insert(:profile)

    meeting_params = %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id
    }

    form_data = %{
      "name" => "Test Attendee",
      "email" => "attendee@test.com",
      "message" => "Test message"
    }

    %{user: user, meeting_params: meeting_params, form_data: form_data}
  end

  # Helper functions for MockCalendar responses
  defp set_calendar_events(events) do
    MockCalendar.set_response({:ok, events})
  end

  defp set_calendar_error(error_type) do
    MockCalendar.set_response({:error, error_type})
  end

  defp set_calendar_empty do
    MockCalendar.set_response({:ok, []})
  end

  defp create_conflicting_event(meeting_params) do
    start_time =
      meeting_params.date
      |> DateTime.new!(~T[14:00:00], meeting_params.user_timezone)
      |> DateTime.shift_zone!("Etc/UTC")

    %{
      uid: "conflict-123",
      start_time: start_time,
      end_time: DateTime.add(start_time, 60, :minute)
    }
  end

  # Mock calendar module that can be configured per test
  defmodule MockCalendar do
    @moduledoc """
    Mock calendar module for testing.
    Uses Agent to store test responses.
    """
    use Agent

    @spec start_link() :: {:ok, pid()} | {:error, term()}
    def start_link do
      Agent.start_link(
        fn -> %{response: {:ok, []}, integration_info: {:error, :no_integration}} end,
        name: __MODULE__
      )
    end

    @spec get_events_for_range_fresh(integer(), Date.t(), Date.t()) ::
            {:ok, list()} | {:error, term()} | term()
    def get_events_for_range_fresh(_user_id, _start_date, _end_date) do
      case Agent.get(__MODULE__, & &1.response) do
        {:ok, events} -> {:ok, events}
        {:error, reason} -> {:error, reason}
        other -> other
      end
    end

    @spec get_booking_integration_info(integer() | map()) :: {:ok, map()} | {:error, term()}
    def get_booking_integration_info(_context) do
      Agent.get(__MODULE__, & &1.integration_info)
    end

    @spec set_response(term()) :: :ok
    def set_response(response) do
      Agent.update(__MODULE__, fn state -> %{state | response: response} end)
    end

    @spec set_integration_info(term()) :: :ok
    def set_integration_info(info) do
      Agent.update(__MODULE__, fn state -> %{state | integration_info: info} end)
    end

    @spec stop() :: :ok
    def stop do
      case Process.whereis(__MODULE__) do
        nil ->
          :ok

        _pid ->
          try do
            Agent.stop(__MODULE__)
          catch
            :exit, _reason -> :ok
          end
      end
    end
  end

  setup do
    # Start mock calendar agent
    {:ok, _pid} = MockCalendar.start_link()

    # Set mock calendar module for tests
    original_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, MockCalendar)

    on_exit(fn ->
      MockCalendar.stop()

      if original_module do
        Application.put_env(:tymeslot, :calendar_module, original_module)
      else
        Application.delete_env(:tymeslot, :calendar_module)
      end
    end)

    :ok
  end

  describe "execute/3 with calendar validation" do
    setup do
      setup_booking_test()
    end

    test "succeeds when calendar check returns :ok", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Mock calendar to return empty events (no conflicts)
      set_calendar_empty()

      assert {:ok, meeting} = Create.execute(meeting_params, form_data)
      assert meeting.uid != nil
      assert meeting.attendee_name == "Test Attendee"
      assert meeting.attendee_email == "attendee@test.com"
    end

    test "fails with slot_unavailable when calendar check detects conflict", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Create a conflicting event at the same instant as the requested slot
      conflicting_event = create_conflicting_event(meeting_params)

      set_calendar_events([conflicting_event])

      # Validation should detect conflict and return user-friendly error message
      assert {:error, "This time slot is no longer available. Please select a different time."} =
               Create.execute(meeting_params, form_data, skip_calendar_check: false)
    end

    test "succeeds when the only overlapping event is TRANSP:TRANSPARENT", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Regression for the "Joep vakantie" bug: an all-day transparent vacation
      # was blocking every booking during its span because the submit path
      # didn't filter events through CalendarEvent.blocking?/1.
      transparent_event =
        meeting_params
        |> create_conflicting_event()
        |> Map.merge(%{status: "confirmed", transparency: "transparent"})

      set_calendar_events([transparent_event])

      assert {:ok, meeting} =
               Create.execute(meeting_params, form_data, skip_calendar_check: false)

      assert meeting.uid != nil
    end

    test "succeeds when the only overlapping event is cancelled", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      cancelled_event =
        meeting_params
        |> create_conflicting_event()
        |> Map.merge(%{status: "cancelled", transparency: "opaque"})

      set_calendar_events([cancelled_event])

      assert {:ok, meeting} =
               Create.execute(meeting_params, form_data, skip_calendar_check: false)

      assert meeting.uid != nil
    end

    test "succeeds when calendar check times out (transport error)", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Mock calendar timeout/network error
      set_calendar_error(:timeout)

      # Should succeed despite calendar error - booking proceeds
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)
      assert meeting.uid != nil
      assert meeting.attendee_name == "Test Attendee"
    end

    test "succeeds when calendar check returns network error", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Mock calendar network error
      set_calendar_error(:network_error)

      # Should succeed despite calendar error
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)
      assert meeting.uid != nil
    end

    test "succeeds when calendar check returns connection error", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Mock calendar connection error
      set_calendar_error(:connection_failed)

      # Should succeed despite calendar error
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)
      assert meeting.uid != nil
    end

    test "succeeds when calendar check returns server error", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Mock calendar server error
      set_calendar_error(:server_error)

      # Should succeed despite calendar error
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)
      assert meeting.uid != nil
    end

    test "inherits calendar and video settings from meeting type", %{
      user: user,
      form_data: form_data
    } do
      # Set up integrations
      calendar_int = insert(:calendar_integration, user: user)
      video_int = insert(:video_integration, user: user)

      # Create meeting type with specific settings
      meeting_type =
        insert(:meeting_type,
          user: user,
          calendar_integration: calendar_int,
          target_calendar_id: "specific-cal-123",
          video_integration: video_int,
          allow_video: true
        )

      # Mock calendar behavior for this meeting type
      MockCalendar.set_integration_info(
        {:ok, %{integration_id: calendar_int.id, calendar_path: "specific-cal-123"}}
      )

      # Set mock calendar to return empty events (no conflicts)
      set_calendar_empty()

      meeting_params = %{
        date: Date.add(Date.utc_today(), 1),
        time: "10:00",
        duration: "30min",
        user_timezone: "UTC",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }

      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      # Verify meeting record inherits settings
      assert meeting.meeting_type_id == meeting_type.id
      assert meeting.video_integration_id == video_int.id
      assert meeting.calendar_integration_id == calendar_int.id
      assert meeting.calendar_path == "specific-cal-123"
      assert meeting.meeting_type == meeting_type.name
    end

    test "rejects meeting_type_id that does not belong to organizer", %{
      user: user,
      form_data: form_data
    } do
      other_user = insert(:user)
      _profile = insert(:profile, user: other_user)

      other_meeting_type = insert(:meeting_type, user: other_user)

      set_calendar_empty()

      meeting_params = %{
        date: Date.add(Date.utc_today(), 1),
        time: "10:30",
        duration: "30min",
        user_timezone: "UTC",
        organizer_user_id: user.id,
        meeting_type_id: other_meeting_type.id
      }

      assert {:error,
              "This meeting type is no longer available. Please go back and select another."} =
               Create.execute(meeting_params, form_data)
    end

    test "ignores video_integration_id that does not belong to organizer", %{
      user: user,
      form_data: form_data
    } do
      other_user = insert(:user)
      _profile = insert(:profile, user: other_user)

      other_video_integration = insert(:video_integration, user: other_user)

      set_calendar_empty()

      meeting_params = %{
        date: Date.add(Date.utc_today(), 1),
        time: "11:00",
        duration: "30min",
        user_timezone: "UTC",
        organizer_user_id: user.id,
        video_integration_id: other_video_integration.id
      }

      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      assert meeting.video_integration_id == nil
      assert meeting.meeting_type == "General Meeting"
    end

    test "fails when meeting type is inactive", %{
      user: user,
      form_data: form_data
    } do
      meeting_type = insert(:meeting_type, user: user, is_active: false)

      set_calendar_empty()

      meeting_params = %{
        date: Date.add(Date.utc_today(), 1),
        time: "12:00",
        duration: "30min",
        user_timezone: "UTC",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }

      assert {:error, "This meeting type is no longer available. Please refresh the page."} =
               Create.execute(meeting_params, form_data)
    end

    test "fails when meeting type has been deleted", %{
      user: user,
      form_data: form_data
    } do
      meeting_type = insert(:meeting_type, user: user, is_active: true)
      deleted_id = meeting_type.id

      # Delete the meeting type
      MeetingTypes.delete_meeting_type(meeting_type)

      set_calendar_empty()

      meeting_params = %{
        date: Date.add(Date.utc_today(), 1),
        time: "12:00",
        duration: "30min",
        user_timezone: "UTC",
        organizer_user_id: user.id,
        meeting_type_id: deleted_id
      }

      assert {:error,
              "This meeting type is no longer available. Please go back and select another."} =
               Create.execute(meeting_params, form_data)
    end
  end

  describe "execute_with_video_room/3 with calendar validation" do
    setup do
      setup_booking_test()
    end

    test "succeeds when calendar check times out", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Mock calendar timeout
      set_calendar_error(:timeout)

      # Should succeed despite calendar error
      assert {:ok, meeting} = Create.execute_with_video_room(meeting_params, form_data)
      assert meeting.uid != nil
    end

    test "fails fast when calendar check detects conflict", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Create a conflicting event at the same instant as the requested slot
      conflicting_event = create_conflicting_event(meeting_params)

      set_calendar_events([conflicting_event])

      # Should fail fast with user-friendly message
      assert {:error, "This time slot is no longer available. Please select a different time."} =
               Create.execute_with_video_room(meeting_params, form_data)
    end
  end

  describe "execute/3 telemetry" do
    setup do
      setup_booking_test()
    end

    test "emits [:tymeslot, :booking, :created] on successful free guest booking", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      set_calendar_empty()

      test_pid = self()

      :telemetry.attach(
        "test-booking-created",
        [:tymeslot, :booking, :created],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-booking-created") end)

      assert {:ok, _meeting} = Create.execute(meeting_params, form_data)
      assert_received {:telemetry, %{count: 1}, %{}}
    end
  end

  describe "execute/3 with custom field validation" do
    setup do
      setup_booking_test()
    end

    test "rejects booking when a required custom field answer is missing", %{
      user: user,
      form_data: form_data
    } do
      set_calendar_empty()

      snapshot = [
        %{
          "id" => "field-1",
          "type" => "short_text",
          "label" => "Company",
          "required" => true
        }
      ]

      meeting_params = %{
        date: Date.add(Date.utc_today(), 1),
        time: "15:00",
        duration: "30min",
        user_timezone: "UTC",
        organizer_user_id: user.id,
        custom_fields_snapshot: snapshot,
        # No answer provided for the required field
        custom_field_answers: %{}
      }

      result = Create.execute(meeting_params, form_data)

      assert {:error, error_msg} = result
      assert error_msg =~ "required"

      # Verify nothing was persisted
      assert Repo.aggregate(MeetingSchema, :count) == 0
    end

    test "accepts booking when all required custom field answers are present", %{
      user: user,
      form_data: form_data
    } do
      set_calendar_empty()

      snapshot = [
        %{
          "id" => "field-1",
          "type" => "short_text",
          "label" => "Company",
          "required" => true
        }
      ]

      meeting_params = %{
        date: Date.add(Date.utc_today(), 1),
        time: "15:30",
        duration: "30min",
        user_timezone: "UTC",
        organizer_user_id: user.id,
        custom_fields_snapshot: snapshot,
        custom_field_answers: %{"field-1" => "Acme Corp"}
      }

      assert {:ok, meeting} = Create.execute(meeting_params, form_data)
      assert meeting.uid != nil
    end

    test "accepts booking when there are no custom fields in the snapshot", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      set_calendar_empty()

      # No snapshot / empty snapshot — baseline behaviour must not regress
      params = Map.merge(meeting_params, %{custom_fields_snapshot: [], custom_field_answers: %{}})

      assert {:ok, meeting} = Create.execute(params, form_data)
      assert meeting.uid != nil
    end
  end
end
