defmodule Tymeslot.Meetings.EmailVerificationRecheckTest do
  @moduledoc """
  Verifying a held booking against its meeting type and invitation as they
  stand when the attendee confirms, not as they stood at booking: a change
  the host made during the hold that a fresh submission would be refused
  under releases the booking instead of confirming it, and starts nothing.
  The rest of the gate is covered by `Tymeslot.Meetings.EmailVerificationTest`.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [where: 2]
  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings
  @moduletag :integration

  alias Tymeslot.Invitations
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.WebhookWorker

  describe "verify/1 after the host changed the type or the invitation" do
    setup do
      TestMocks.stub_no_calendar_events()
      user = insert(:user)
      insert(:profile, user: user)
      %{user: user}
    end

    # The type's settings decide what verifying does (approval, above); with
    # the type gone they cannot be read, so the booking must not go ahead
    # without the approval it may have needed.
    test "a held booking whose meeting type was deleted is released, not confirmed", %{
      user: user
    } do
      type = insert(:meeting_type, user: user, requires_approval: true)
      meeting = held(user, meeting_type_id: type.id)
      :ok = EmailVerificationJobs.schedule_expiry(meeting)
      Repo.delete!(type)

      assert {:error, :expired} = EmailVerification.verify(reload(meeting))

      assert %{status: :expired, email_verified_at: nil} = reload(meeting)
      refute_enqueued(worker: EmailVerificationExpiryWorker)
      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: VideoRoomWorker)
      refute_enqueued(worker: EmailWorker)
      refute_enqueued(worker: WebhookWorker)
    end

    test "an archived meeting type's settings still apply", %{user: user} do
      type =
        insert(:meeting_type,
          user: user,
          requires_approval: true,
          approval_window_hours: 24,
          is_archived: true
        )

      meeting = held(user, meeting_type_id: type.id)

      assert {:ok, :verified, %{status: :awaiting_approval}} = EmailVerification.verify(meeting)
    end

    # A fresh submission on either type would be refused
    # (`:meeting_type_inactive`, `:series_required`), so the held one is not
    # confirmed past the host's change either.
    for {became, changes} <- [
          {"deactivated", [is_active: false]},
          {"series-only",
           [
             series_mode: :recurring,
             series_frequency: :weekly,
             series_interval: 1,
             series_min_occurrences: 2,
             series_max_occurrences: 12,
             series_required: true
           ]}
        ] do
      test "a held booking whose meeting type was #{became} is released", %{user: user} do
        type = insert(:meeting_type, user: user)
        meeting = held(user, meeting_type_id: type.id)
        :ok = EmailVerificationJobs.schedule_expiry(meeting)

        Repo.update_all(where(MeetingTypeSchema, id: ^type.id), set: unquote(changes))

        assert {:error, :expired} = EmailVerification.verify(meeting)

        assert %{status: :expired, email_verified_at: nil} = reload(meeting)
        refute_enqueued(worker: EmailVerificationExpiryWorker)
        refute_enqueued(worker: CalendarEventWorker)
        refute_enqueued(worker: EmailWorker)
        refute_enqueued(worker: WebhookWorker)
      end
    end

    test "a held booking whose type took a series that still allows single sessions is confirmed",
         %{user: user} do
      type = insert(:meeting_type, user: user)
      meeting = held(user, meeting_type_id: type.id)

      Repo.update_all(where(MeetingTypeSchema, id: ^type.id),
        set: [
          series_mode: :recurring,
          series_frequency: :weekly,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 12,
          series_required: false
        ]
      )

      assert {:ok, :verified, %{status: :confirmed}} = EmailVerification.verify(meeting)
    end

    # The type's rules refuse verification alongside payment or seats, so a
    # host who wants either turns verification off in the same save;
    # confirming the held booking then would skip the payment or the seat.
    for {became, changes} <- [
          {"paid", [payment_required: true]},
          {"a group type", [max_participants: 5]}
        ] do
      test "a held booking whose meeting type became #{became} is released", %{user: user} do
        type = insert(:meeting_type, user: user)
        meeting = held(user, meeting_type_id: type.id)
        :ok = EmailVerificationJobs.schedule_expiry(meeting)

        Repo.update_all(where(MeetingTypeSchema, id: ^type.id),
          set: [requires_email_verification: false] ++ unquote(changes)
        )

        assert {:error, :expired} = EmailVerification.verify(meeting)

        assert %{status: :expired, email_verified_at: nil} = reload(meeting)
        refute_enqueued(worker: EmailVerificationExpiryWorker)
        refute_enqueued(worker: CalendarEventWorker)
        refute_enqueued(worker: EmailWorker)
        refute_enqueued(worker: WebhookWorker)
      end
    end

    # The organiser never saw the held booking, so they may revoke the link it
    # came through; the booking must not then appear on their calendar.
    test "a booking through an invitation revoked during the hold is released", %{user: user} do
      type = insert(:meeting_type, user: user, invitation_only: true)
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      meeting = held(user, meeting_type_id: type.id, invitation_id: invitation.id)
      :ok = EmailVerificationJobs.schedule_expiry(meeting)
      {:ok, _revoked} = Invitations.revoke(user.id, invitation.id)

      assert {:error, :expired} = EmailVerification.verify(meeting)

      assert %{status: :expired, email_verified_at: nil} = reload(meeting)
      refute_enqueued(worker: EmailVerificationExpiryWorker)
      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: EmailWorker)
      refute_enqueued(worker: WebhookWorker)
    end

    test "a booking through an invitation still open is confirmed", %{user: user} do
      type = insert(:meeting_type, user: user, invitation_only: true)
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      meeting = held(user, meeting_type_id: type.id, invitation_id: invitation.id)

      assert {:ok, :verified, %{status: :confirmed}} = EmailVerification.verify(meeting)
    end
  end

  defp held(user, attrs) do
    defaults = [
      organizer_user_id: user.id,
      organizer_email: user.email,
      video_integration_id: nil
    ]

    attrs =
      Keyword.put_new_lazy(attrs, :meeting_type_id, fn ->
        insert(:meeting_type, user: user).id
      end)

    insert(:awaiting_verification_meeting, Keyword.merge(defaults, attrs))
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)
end
