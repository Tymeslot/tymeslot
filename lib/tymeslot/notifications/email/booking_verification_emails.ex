defmodule Tymeslot.Notifications.Email.BookingVerificationEmails do
  @moduledoc """
  Handles the email that asks an attendee to verify their address before a
  booking counts.

  Each send is its own job: its args carry a `"send"` number (1 when absent),
  which is part of the job's Oban uniqueness, so a later resend is a different
  job and is not swallowed by the first one's uniqueness, while a duplicate
  enqueue of the same send within the uniqueness period is. The send number is
  counted atomically on the booking
  (`Tymeslot.Meetings.MeetingTransitionQueries.count_verification_email/3`), so two
  resends never share a number. The delivery claim
  (`Tymeslot.Workers.DeliveryClaims.once/3`) is keyed by the job's id, so it
  only stops a retry of the same job from sending twice; it does nothing
  across jobs.
  """

  require Logger

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.Email.SeatJobs
  alias Tymeslot.Workers.DeliveryClaims

  @booking_not_held "Booking no longer awaiting verification"
  @seat_not_held "Seat no longer awaiting verification"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected
  outcome: the attendee verified, or the hold lapsed, before the job ran.
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason), do: reason in [@booking_not_held, @seat_not_held]

  @doc """
  Sends the verification link to the attendee of a held booking.

  Discards the job when the booking is no longer held (verified, expired or
  gone) or its deadline has passed, so a link is never sent for a hold that
  has lapsed. The token is signed here, from the current row, and never stored
  in the job args: Oban rows are readable by operators and outlive the hold.
  """
  @spec handle_verification_email(%{String.t() => term()}, integer() | nil) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_verification_email(%{"meeting_id" => meeting_id} = args, job_id) do
    MeetingEmails.with_meeting(meeting_id, "booking email verification", fn meeting ->
      if held_and_in_time?(meeting) do
        send_link(meeting, claim_key(args), job_id)
      else
        Logger.info("Skipping verification email - booking no longer held",
          meeting_id: meeting_id,
          status: meeting.status
        )

        {:discard, @booking_not_held}
      end
    end)
  end

  @doc """
  Sends the verification link to one held seat of a group meeting.

  Discards the job when the seat is cancelled, verified or past its deadline,
  or when its slot no longer holds its time
  (`Tymeslot.Meetings.EmailVerification.seat_standing/3`). The token is signed here from
  the current row and never stored in the job args.
  """
  @spec handle_seat_verification_email(%{String.t() => term()}, integer() | nil) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_seat_verification_email(
        %{"meeting_id" => meeting_id, "participant_id" => participant_id} = args,
        job_id
      ) do
    SeatJobs.with_seat(
      meeting_id,
      participant_id,
      "seat email verification",
      {:live_slot, :live},
      fn slot, seat ->
        if seat_held_and_in_time?(slot, seat) do
          send_seat_link(slot, seat, seat_claim_key(args), job_id)
        else
          Logger.info("Skipping seat verification email - seat no longer held",
            meeting_id: meeting_id,
            participant_id: participant_id
          )

          {:discard, @seat_not_held}
        end
      end
    )
  end

  defp seat_held_and_in_time?(slot, seat),
    do: ParticipantSchema.unverified?(seat) and EmailVerification.seat_live?(slot, seat)

  defp seat_claim_key(args), do: "seat_verification:attendee:#{Map.get(args, "send", 1)}"

  defp send_seat_link(slot, seat, key, job_id) do
    result =
      DeliveryClaims.once(job_id, key, fn ->
        url = seat |> EmailVerificationToken.sign_seat() |> MeetingLinks.verification_url()

        with {:ok, _sent} <-
               Config.email_service_module().send_seat_email_verification(slot, seat, url),
             do: :ok
      end)

    SeatJobs.send_result(result, "verification", meeting_id: slot.id, participant_id: seat.id)
  end

  defp held_and_in_time?(%Meeting{verification_deadline_at: %DateTime{} = deadline} = meeting) do
    MeetingState.awaiting_verification?(meeting) and
      DateTime.compare(Clock.utc_now(), deadline) == :lt
  end

  defp held_and_in_time?(_meeting), do: false

  defp claim_key(args), do: "booking_verification:attendee:#{Map.get(args, "send", 1)}"

  defp send_link(meeting, key, job_id) do
    result =
      DeliveryClaims.once(job_id, key, fn ->
        url = meeting |> EmailVerificationToken.sign() |> MeetingLinks.verification_url()

        with {:ok, _sent} <-
               Config.email_service_module().send_booking_email_verification(meeting, url),
             do: :ok
      end)

    DeliveryOutcome.combine("booking verification", [meeting_id: meeting.id], [result])
  end
end
