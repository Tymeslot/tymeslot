defmodule Tymeslot.Bookings.CreateErrorTrackingTest do
  @moduledoc """
  Booking creation records in ErrorTracker only the failures nobody
  anticipated. A lost race and input the meeting changeset refuses are
  expected outcomes, and a database failure is recorded once, where
  `Meetings.Scheduling` rescued it, not a second time by `Create`.
  """

  # async: false: ErrorTracker's `enabled` switch and the telemetry handler
  # are global.
  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :integration

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.Bookings.Create

  @telemetry_handler "create-error-tracking-test-occurrences"

  @doc false
  @spec forward_occurrence([atom()], map(), map(), pid()) :: :ok
  def forward_occurrence(_event, _measurements, _metadata, test_pid) do
    send(test_pid, :occurrence_recorded)
    :ok
  end

  setup do
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    with_config(:error_tracker, enabled: true)

    :ok =
      :telemetry.attach(
        @telemetry_handler,
        [:error_tracker, :occurrence, :new],
        &__MODULE__.forward_occurrence/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(@telemetry_handler) end)

    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
    meeting_type = insert(:meeting_type, user: user)

    meeting_params = %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    form_data = %{"name" => "Test Attendee", "email" => "attendee@test.com", "message" => ""}

    %{meeting_params: meeting_params, form_data: form_data}
  end

  defp book(meeting_params, form_data) do
    capture_log(fn ->
      send(
        self(),
        {:result, Create.execute(meeting_params, form_data, skip_calendar_check: true)}
      )
    end)

    assert_received {:result, result}
    result
  end

  test "a slot lost to a concurrent booking records nothing", %{
    meeting_params: meeting_params,
    form_data: form_data
  } do
    assert {:ok, _meeting} = book(meeting_params, form_data)

    assert {:error, :slot_taken} =
             book(meeting_params, %{form_data | "email" => "other@test.com"})

    refute_receive :occurrence_recorded, 300
    assert Repo.all(Error) == []
  end

  test "input the meeting changeset refuses records nothing", %{
    meeting_params: meeting_params,
    form_data: form_data
  } do
    assert {:error, :booking_failed} =
             book(meeting_params, %{form_data | "email" => "not-an-email"})

    # Any report, including one Scheduling offloads to a task, would arrive
    # within this window.
    refute_receive :occurrence_recorded, 300
    assert Repo.all(Error) == []
  end

  test "a database failure is recorded once, as the exception Scheduling rescued", %{
    meeting_params: meeting_params,
    form_data: form_data
  } do
    Repo.query!("""
    CREATE FUNCTION fail_meeting_insert() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'meetings unavailable'; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER fail_meeting_insert BEFORE INSERT ON meetings
    FOR EACH ROW EXECUTE FUNCTION fail_meeting_insert()
    """)

    assert {:error, :booking_failed} = book(meeting_params, form_data)

    # Scheduling reports from inside the booking transaction, so its report
    # is made by a separate process.
    assert_receive :occurrence_recorded, 2_000
    refute_receive :occurrence_recorded, 300

    assert [%Error{kind: "Elixir.Postgrex.Error"}] = Repo.all(Error)
  end
end
