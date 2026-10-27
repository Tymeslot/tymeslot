defmodule Tymeslot.Bookings.ConfirmationCommitsWithBookingTest do
  @moduledoc """
  Every path that creates or confirms a booking commits its confirmation
  emails and reminders with it, or neither. A booking whose confirmation
  cannot be queued is not made (or not confirmed), its announcement claim is
  left free, and the retry, whoever makes it, confirms it once.

  The paid checkout, which Stripe retries, is covered through its webhook
  endpoint in `TymeslotWeb.PaidBookingConfirmationRetryTest`.
  """

  # async: false: the confirmation insert is refused by patching Oban.insert/1
  # with :meck, which replaces the module for every process.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers
  import Tymeslot.WorkerTestHelpers

  @moduletag :bookings
  @moduletag :integration

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  setup do
    TestMocks.stub_no_calendar_events()

    # The real email service, so each retry is shown to send the confirmation.
    Application.put_env(:swoosh, :shared_test_process, self())
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    on_exit(fn ->
      Application.delete_env(:swoosh, :shared_test_process)
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
    end)

    :ok
  end

  test "a booking whose confirmation cannot be queued is not made, and booking again makes it once" do
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

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

    refusing_confirmation(fn ->
      assert {:error, :booking_failed} =
               quietly(fn -> Create.execute(meeting_params, form_data) end)
    end)

    assert Repo.all(MeetingSchema) == []
    assert all_enqueued(worker: EmailWorker) == []

    assert {:ok, meeting} = Create.execute(meeting_params, form_data)
    assert_one_confirmation(meeting)
  end

  test "a host's meeting whose confirmation cannot be queued is not made, and a retry makes it once" do
    user = insert(:user)
    insert(:profile, user: user)
    start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

    params = %{
      title: "Quick sync",
      start_time: start_time,
      end_time: DateTime.add(start_time, 1, :hour),
      attendee_name: "Jane Doe",
      attendee_email: "jane@example.com",
      attendee_timezone: "Europe/Berlin",
      organizer_user_id: user.id,
      calendar_integration_id: nil,
      calendar_path: nil,
      video_integration_id: nil
    }

    refusing_confirmation(fn ->
      assert {:error, :meeting_creation_failed} = quietly(fn -> CreateAdHoc.execute(params) end)
    end)

    assert Repo.all(MeetingSchema) == []

    assert {:ok, meeting} = CreateAdHoc.execute(params)
    assert_one_confirmation(meeting)
  end

  test "an approval whose confirmation cannot be queued leaves the request held, and approving again confirms it once" do
    meeting = held_request()

    refusing_confirmation(fn ->
      assert {:error, :not_scheduled} = quietly(fn -> Approval.approve(meeting) end)
    end)

    assert %{status: "awaiting_approval", announced_at: nil, approval_resolved_at: nil} =
             reload(meeting)

    assert all_enqueued(worker: EmailWorker, args: %{"action" => "send_confirmation_emails"}) ==
             []

    assert {:ok, %{status: "confirmed"}} = Approval.approve(meeting)
    assert_one_confirmation(meeting)
  end

  # A reschedule confirms a held request outright once its meeting type has
  # stopped requiring approval; that confirmation is the booking's first.
  test "a reschedule confirming a held request outright is refused whole when its confirmation cannot be queued" do
    TestMocks.setup_email_mocks()
    %{user: user} = create_always_bookable_profile()
    meeting_type = insert(:meeting_type, user: user, user_id: user.id, requires_approval: false)

    meeting =
      insert_meeting_for_user(user, %{
        meeting_type_id: meeting_type.id,
        status: "awaiting_approval",
        approval_requested_at: DateTime.add(DateTime.utc_now(:second), -1, :hour),
        approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 11, :hour)
      })

    params = %{
      date: Date.to_string(Date.add(Date.utc_today(), 2)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }

    refusing_confirmation(fn ->
      assert {:error, :failed_to_update_meeting} =
               quietly(fn -> Reschedule.execute(meeting.uid, params, user.id) end)
    end)

    assert %{status: "awaiting_approval", announced_at: nil} = reload(meeting)
    assert DateTime.compare(reload(meeting).start_time, meeting.start_time) == :eq

    assert {:ok, %{status: "confirmed"}} = Reschedule.execute(meeting.uid, params, user.id)
    assert_one_confirmation(meeting)
  end

  describe "the video room job announcing a booking" do
    test "retries instead of giving up when the booking's confirmation cannot be queued" do
      user = insert(:user)
      insert(:profile, user: user)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: nil
        )

      args = %{"meeting_id" => meeting.id, "announce" => true}

      refusing_confirmation(fn ->
        assert {:error, {:announcement_failed, _reason}} =
                 quietly(fn -> perform_job(VideoRoomWorker, args, attempt: 1) end)
      end)

      assert %{announced_at: nil} = reload(meeting)

      assert {:discard, "Video integration missing"} =
               perform_job(VideoRoomWorker, args, attempt: 2)

      assert_one_confirmation(meeting)
    end

    test "retries when the room exists but the confirmation cannot be queued, and announces once" do
      %{meeting: meeting} = setup_video_scenario()
      expect_mirotalk_success()
      args = %{"meeting_id" => meeting.id, "announce" => true}

      refusing_confirmation(fn ->
        assert {:error, {:announcement_failed, _reason}} =
                 quietly(fn -> perform_job(VideoRoomWorker, args) end)
      end)

      # The room was created and kept; only the announcement is owed.
      assert %{announced_at: nil, video_room_id: "https://test.mirotalk.com/join/test-room-123"} =
               reload(meeting)

      assert :ok = perform_job(VideoRoomWorker, args)
      assert_one_confirmation(meeting)
    end
  end

  defp held_request do
    user = insert(:user)
    insert(:profile, user: user)

    insert(:meeting,
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      organizer_email: user.email,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
    )
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  # One confirmation job, and draining it emails the attendee and the
  # organiser once each: nothing the failed attempt queued survived it.
  defp assert_one_confirmation(meeting) do
    assert [_one] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
             )

    meeting = reload(meeting)
    assert %DateTime{} = meeting.announced_at

    assert %{failure: 0} = Oban.drain_queue(queue: :emails)

    assert Enum.sort(sent_to()) == Enum.sort([meeting.attendee_email, meeting.organizer_email])
  end

  defp sent_to do
    receive do
      {:email, email} -> Enum.map(email.to, fn {_name, address} -> address end) ++ sent_to()
    after
      0 -> []
    end
  end

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  # Every confirmation-email insert reports a failure; other jobs insert.
  defp refusing_confirmation(fun) do
    :meck.new(Oban, [:passthrough])

    :meck.expect(Oban, :insert, fn changeset ->
      if Changeset.get_field(changeset, :args)["action"] == "send_confirmation_emails",
        do: {:error, :queue_not_available},
        else: :meck.passthrough([changeset])
    end)

    try do
      fun.()
    after
      :meck.unload(Oban)
    end
  end
end
