defmodule Tymeslot.Bookings.CreateEmailVerificationTest do
  @moduledoc """
  Booking a meeting type that requires the attendee to verify their email
  address: the booking is held, the attendee is emailed, and nothing else
  happens until they confirm.

  The assertions worth breaking things over are the negative ones: a held
  booking that schedules a calendar event, a video room, a confirmation, a
  guest invitation or a webhook has told someone about a booking whose
  address nobody has proved.
  """

  # async: false: the email insert is refused by patching Oban.insert/1 with
  # :meck, which replaces the module for every process.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [create_always_bookable_profile: 1]
  import Tymeslot.Test.ClockHelpers

  @moduletag :bookings
  @moduletag :integration

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Invitations
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    TestMocks.stub_no_calendar_events()

    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
    %{user: user}
  end

  defp gated_type(user, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [user: user, requires_email_verification: true, is_active: true, duration_minutes: 60],
        attrs
      )
    )
  end

  defp book(user, type, overrides \\ %{}) do
    %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: type.id
    }
    |> Map.merge(overrides)
    |> Create.execute(%{
      "name" => "Test Attendee",
      "email" => "attendee@test.com",
      "message" => ""
    })
  end

  defp email_actions do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.map(& &1.args["action"])
  end

  test "a gated booking is held, emailed and nothing else", %{user: user} do
    now = DateTime.utc_now(:second)
    freeze_clock(now)

    # An ungated booking of this type would enqueue a room job, so the refute
    # below can fail. (The room job is what announces such a booking, so its
    # webhook is refuted in the next test, on a type without video.)
    video = insert(:video_integration, user: user)

    type = gated_type(user, video_integration: video, allow_video: true)

    assert {:ok, %{status: :awaiting_verification} = meeting} = book(user, type)

    assert meeting.verification_deadline_at == DateTime.add(now, 30, :minute)
    assert meeting.email_verified_at == nil

    assert Repo.get!(MeetingSchema, meeting.id).status == :awaiting_verification

    assert email_actions() == ["send_booking_email_verification"]

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_booking_email_verification", "meeting_id" => meeting.id}
    )

    assert [expiry] = all_enqueued(worker: EmailVerificationExpiryWorker)
    assert expiry.args == %{"meeting_id" => meeting.id}
    assert DateTime.compare(expiry.scheduled_at, meeting.verification_deadline_at) == :eq

    refute_enqueued(worker: CalendarEventWorker)
    refute_enqueued(worker: VideoRoomWorker)
  end

  test "a gated booking that also needs approval asks the host nothing yet", %{user: user} do
    type = gated_type(user, requires_approval: true)

    assert {:ok, %{status: :awaiting_verification} = meeting} = book(user, type)
    assert meeting.approval_requested_at == nil
    assert meeting.approval_deadline_at == nil
    assert email_actions() == ["send_booking_email_verification"]
  end

  test "a gated booking fires no webhook", %{user: user} do
    # Subscribed to the event an ungated booking of this type delivers at once.
    insert(:webhook, user: user, events: ["meeting.created"])
    type = gated_type(user)

    assert {:ok, %{status: :awaiting_verification}} = book(user, type)

    refute_enqueued(worker: WebhookWorker)
  end

  test "a gated booking holds its slot", %{user: user} do
    type = gated_type(user)

    assert {:ok, %{status: :awaiting_verification}} = book(user, type)
    assert {:error, :slot_taken} = book(user, type)
  end

  test "a gated booking counts against booking limits", %{user: user} do
    type = gated_type(user, max_bookings_per_day: 1)

    assert {:ok, %{status: :awaiting_verification}} = book(user, type)
    assert {:error, :booking_limit_reached} = book(user, type, %{time: "16:00"})
  end

  test "an invitation is held while the booking awaits verification", %{user: user} do
    type = gated_type(user, invitation_only: true)
    {:ok, invitation} = Invitations.create(user.id, type, %{})

    assert {:ok, held} = book(user, type, %{invitation_id: invitation.id})
    assert held.invitation_id == invitation.id

    assert {:error, :invitation_unavailable} =
             book(user, type, %{date: Date.add(Date.utc_today(), 2), invitation_id: invitation.id})

    assert {:ok, %{status: :expired}} = EmailVerification.expire(held)

    assert {:ok, %{invitation_id: invitation_id}} =
             book(user, type, %{date: Date.add(Date.utc_today(), 2), invitation_id: invitation.id})

    assert invitation_id == invitation.id
  end

  test "guests are recorded but not invited", %{user: user} do
    type = gated_type(user, allow_guests: true)

    assert {:ok, meeting} = book(user, type, %{guest_emails: ["guest@example.com"]})

    assert ["guest@example.com"] ==
             meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email)

    refute_enqueued(worker: EmailWorker, args: %{"action" => "send_guest_invitations"})
    assert email_actions() == ["send_booking_email_verification"]
  end

  test "if the verification email cannot be queued the booking is not made", %{user: user} do
    type = gated_type(user)

    refusing("send_booking_email_verification", fn ->
      assert {:error, :booking_failed} = quietly(fn -> book(user, type) end)
    end)

    assert Repo.all(MeetingSchema) == []
    assert all_enqueued(worker: EmailVerificationExpiryWorker) == []
  end

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  # Every insert of an email job with this action reports a failure; other
  # jobs insert.
  defp refusing(action, fun) do
    :meck.new(Oban, [:passthrough])

    :meck.expect(Oban, :insert, fn changeset ->
      if Changeset.get_field(changeset, :args)["action"] == action,
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
