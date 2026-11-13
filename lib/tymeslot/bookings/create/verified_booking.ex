defmodule Tymeslot.Bookings.Create.VerifiedBooking do
  @moduledoc """
  Creating a booking that waits for its attendee to confirm their email
  address before it counts.

  It lives apart from the free path, as `Tymeslot.Bookings.Create.PaidBooking`
  does, because what it does after the insert is different in kind rather than
  in detail: the free path tells the world about the booking, and this one
  deliberately tells nobody but the attendee.

  ## What is done now

  In one transaction: the meeting is inserted `:awaiting_verification`, with
  its deadline (`Tymeslot.Meetings.EmailVerification.gate_attributes/2`), under
  the same conflict check, schedule lock and booking limits as a free booking;
  its guest rows are recorded; the verification email is queued; and the
  expiry job is scheduled at the deadline. A booking whose email cannot be
  queued is not made. The held booking occupies its slot, counts against
  booking limits and holds its invitation, so nobody else can take any of them
  while the attendee is checking their inbox.

  ## What is held back

  Everything that would let the organiser, or anyone but the attendee, learn of
  the booking: no calendar event, no video room, no confirmation or request
  email, no guest invitations, no webhooks or other notifications, and no
  booking telemetry. The approval fields are left unstamped, so an approval
  window starts only at verification.

  All of it resumes in `Tymeslot.Meetings.EmailVerification.verify/1`, which
  moves the booking on exactly as an ungated booking would have been at
  creation. A booking never verified is expired silently at its deadline.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  @doc """
  Creates the held meeting, its guests, its verification email and its expiry
  job, all or none.

  Takes the callbacks the caller already owns rather than reaching back into
  `Create`: `create_meeting` applies the conflict check, `create_guests`
  applies the guest policy, and `classify_error` maps a raw failure onto the
  caller's semantic error vocabulary.
  """
  @spec create(map(), map(), keyword()) :: {:ok, Meeting.t()} | {:error, term()}
  def create(meeting_attrs, booking_data, callbacks) do
    create_meeting = Keyword.fetch!(callbacks, :create_meeting)
    create_guests = Keyword.fetch!(callbacks, :create_guests)
    classify_error = Keyword.fetch!(callbacks, :classify_error)

    attrs =
      Map.merge(
        meeting_attrs,
        EmailVerification.gate_attributes(Clock.utc_now(), meeting_attrs.start_time)
      )

    case hold(attrs, booking_data, create_meeting, create_guests) do
      {:ok, meeting} ->
        # After the commit: it invalidates caches other processes read.
        Availability.changed(meeting.organizer_user_id)
        {:ok, meeting}

      {:error, reason} ->
        {:error, classify_error.(reason)}
    end
  end

  defp hold(attrs, booking_data, create_meeting, create_guests) do
    Repo.transaction(fn ->
      with {:ok, meeting} <- create_meeting.(attrs),
           {:ok, _guests} <- create_guests.(meeting, booking_data),
           :ok <- EmailScheduler.schedule_verification_email(meeting.id) do
        :ok = EmailVerificationJobs.schedule_expiry(meeting)
        meeting
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
