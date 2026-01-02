defmodule Tymeslot.Bookings.CreateTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false

  alias __MODULE__.MockCalendar
  alias Tymeslot.Bookings.Create

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
      Agent.start_link(fn -> %{response: {:ok, []}} end, name: __MODULE__)
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

    @spec set_response(term()) :: :ok
    def set_response(response) do
      Agent.update(__MODULE__, fn _ -> %{response: response} end)
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
            :exit, _ -> :ok
          end
      end
    end
  end

  setup do
    # Start mock calendar agent
    {:ok, _} = MockCalendar.start_link()

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

      # Validation should detect conflict and return slot_unavailable
      # This gets converted to user-friendly error message in Orchestrator
      assert {:error, :slot_unavailable} =
               Create.execute(meeting_params, form_data, skip_calendar_check: false)
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
end
