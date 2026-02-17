defmodule Tymeslot.Integrations.Calendar.EntryTest do
  use Tymeslot.DataCase, async: true

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.DatabaseSchemas.MeetingTypeSchema
  alias Tymeslot.Integrations.Calendar

  setup :verify_on_exit!

  test "create_event forwards meeting context to calendar module" do
    meeting = insert(:meeting)
    event_data = %{summary: "Test"}

    expect(Tymeslot.CalendarMock, :create_event, fn ^event_data, %MeetingSchema{} = meeting_arg ->
      assert meeting_arg.id == meeting.id
      {:ok, %{uid: "calendar-uid"}}
    end)

    assert {:ok, %{uid: "calendar-uid"}} = Calendar.create_event(event_data, meeting)
  end

  test "create_event forwards meeting type context to calendar module" do
    meeting_type = insert(:meeting_type)
    event_data = %{summary: "Test"}

    expect(Tymeslot.CalendarMock, :create_event, fn ^event_data,
                                                    %MeetingTypeSchema{} = meeting_type_arg ->
      assert meeting_type_arg.id == meeting_type.id
      {:ok, %{uid: "calendar-uid"}}
    end)

    assert {:ok, %{uid: "calendar-uid"}} = Calendar.create_event(event_data, meeting_type)
  end

  test "create_event returns error for invalid context type" do
    event_data = %{summary: "Test"}

    # Should not call the mock for invalid context
    expect(Tymeslot.CalendarMock, :create_event, 0, fn _arg1, _arg2 -> {:ok, %{}} end)

    assert {:error, :invalid_context} = Calendar.create_event(event_data, "invalid_string")
    assert {:error, :invalid_context} = Calendar.create_event(event_data, %{some: "map"})
    assert {:error, :invalid_context} = Calendar.create_event(event_data, -5)
    assert {:error, :invalid_context} = Calendar.create_event(event_data, 0)
  end

  test "create_event handles nil context" do
    event_data = %{summary: "Test"}

    expect(Tymeslot.CalendarMock, :create_event, fn ^event_data, nil ->
      {:ok, %{uid: "calendar-uid-nil"}}
    end)

    assert {:ok, %{uid: "calendar-uid-nil"}} = Calendar.create_event(event_data, nil)
  end

  test "create_event handles user_id context" do
    event_data = %{summary: "Test"}
    user_id = 123

    expect(Tymeslot.CalendarMock, :create_event, fn ^event_data, ^user_id ->
      {:ok, %{uid: "calendar-uid-user"}}
    end)

    assert {:ok, %{uid: "calendar-uid-user"}} = Calendar.create_event(event_data, user_id)
  end

  test "create_event propagates errors from calendar module" do
    meeting = insert(:meeting)
    event_data = %{summary: "Test"}

    expect(Tymeslot.CalendarMock, :create_event, fn ^event_data, %MeetingSchema{} ->
      {:error, :no_calendar_client}
    end)

    assert {:error, :no_calendar_client} = Calendar.create_event(event_data, meeting)
  end
end
