defmodule Tymeslot.Notifications.Email.BookingVerificationEmails do
  @moduledoc """
  Handles the email that asks an attendee to verify their address before a
  booking counts.

  The job is sent once per *send*: its args carry a `"send"` number (1 when
  absent), which is part of both the job's uniqueness and the delivery claim,
  so a later resend is a different send and is neither swallowed by the first
  job's uniqueness nor by its claim, while a duplicate enqueue of the same
  send still is.
  """

  require Logger

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Workers.DeliveryClaims

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

        {:discard, "Meeting #{meeting.status}"}
      end
    end)
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
