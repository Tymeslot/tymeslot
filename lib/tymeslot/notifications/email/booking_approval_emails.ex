defmodule Tymeslot.Notifications.Email.BookingApprovalEmails do
  @moduledoc """
  Handles the approval-gated booking email actions: the request emails sent
  when a host must approve a booking, the mid-window nudge, and the outcome
  email sent once a request is declined or expires.
  """

  require Logger

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Workers.DeliveryClaims

  @doc """
  Sends the invitee's acknowledgement and the host's request.

  The two are independent notifications to different people, so neither
  gates the other: both are attempted on every execution, and the host leg
  runs whether or not the invitee's acknowledgement succeeded. A permanently
  rejected or slow-to-retry invitee address must never leave the host
  unaware a booking request exists at all.

  Each leg is claimed for the job (`DeliveryClaims.once/3`), so when one
  fails the job fails and Oban retries it, and the retry sends only the leg
  that has not gone out.

  Both are guarded on the meeting still being held. A request answered, or
  withdrawn by the invitee, between enqueue and execution must not produce an
  email telling either party it is still open.

  A follow-up job queued by older code carries `"skip_attendee_ack"` or
  `"skip_host_request"`: the leg it names went out before, so it counts as
  sent.
  """
  @spec handle_booking_request_emails(%{String.t() => term()}, integer() | nil) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_booking_request_emails(%{"meeting_id" => meeting_id} = args, job_id) do
    with_held_request(meeting_id, "booking request emails", fn meeting ->
      send_both_legs(meeting, args, job_id)
    end)
  end

  defp send_both_legs(meeting, args, job_id) do
    service = Config.email_service_module()
    email_opts = previous_start_opts(args)

    attendee =
      leg(job_id, "booking_request:attendee_ack", args["skip_attendee_ack"], fn ->
        send_request_received(meeting, service, email_opts)
      end)

    host =
      leg(job_id, "booking_request:host_request", args["skip_host_request"], fn ->
        send_approval_request(:request, meeting, service, email_opts)
      end)

    # A failure that a retry can fix outweighs a rejected address, so a
    # suppressed invitee address never stops the host's retry.
    DeliveryOutcome.combine("booking request", [meeting_id: meeting.id], [attendee, host])
  end

  defp leg(_job_id, _key, true, _send), do: :ok

  defp leg(job_id, key, _skip, send) do
    DeliveryClaims.once(job_id, key, fn ->
      with {:ok, _sent} <- send.(), do: :ok
    end)
  end

  # Set by a reschedule that sent a confirmed booking back into the gate:
  # the time it was moved from, for the emails to show. Only this application
  # writes it, as ISO 8601, so one that does not parse is a bug; the emails
  # still go, without the previous time.
  defp previous_start_opts(%{"previous_start_time" => iso} = args) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, previous, _offset} ->
        [previous_start_time: previous]

      {:error, reason} ->
        ErrorTracking.report_error({:unreadable_previous_start_time, reason}, nil,
          meeting_id: args["meeting_id"]
        )

        []
    end
  end

  defp previous_start_opts(_args), do: []

  defp send_request_received(meeting, service, []),
    do: service.send_booking_request_received(meeting)

  defp send_request_received(meeting, service, email_opts),
    do: service.send_booking_request_received(meeting, email_opts)

  @doc """
  Reminds a host who has not answered yet, once, partway through the window.

  `approval_nudge_sent_at` is the durable guard: an Oban retry after a
  successful send would otherwise deliver a second copy.
  """
  @spec handle_booking_approval_nudge(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_booking_approval_nudge(%{"meeting_id" => meeting_id}) do
    with_held_request(meeting_id, "approval nudge", fn meeting ->
      if meeting.approval_nudge_sent_at do
        Logger.info("Skipping approval nudge - already sent", meeting_id: meeting_id)
        :ok
      else
        send_nudge(meeting)
      end
    end)
  end

  @doc """
  Tells the invitee a request was declined or expired.

  Unlike the other approval emails this one is *not* guarded on the request
  still being held: by the time it runs the request has been answered, which
  is precisely why it is being sent. It is guarded on the status matching the
  variant instead, so a decline email cannot be delivered for a request that
  a later reschedule returned to the gate.
  """
  @spec handle_booking_request_outcome(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_booking_request_outcome(%{"meeting_id" => meeting_id, "variant" => variant})
      when variant in ["declined", "expired"] do
    MeetingEmails.with_meeting(meeting_id, "booking request outcome", fn meeting ->
      send_outcome(meeting, String.to_existing_atom(variant))
    end)
  end

  defp send_outcome(meeting, variant) do
    if outcome_still_true?(meeting, variant) do
      deliver_outcome(meeting, variant)
    else
      Logger.info("Skipping booking request outcome - status no longer matches",
        meeting_id: meeting.id,
        email_action: variant,
        status: meeting.status
      )

      {:discard, "Meeting #{meeting.status}"}
    end
  end

  defp outcome_still_true?(%{status: "cancelled"}, :declined), do: true
  defp outcome_still_true?(%{status: "expired"}, :expired), do: true
  defp outcome_still_true?(_meeting, _variant), do: false

  defp deliver_outcome(meeting, variant) do
    case Config.email_service_module().send_booking_request_outcome(variant, meeting) do
      {:ok, _sent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Tells the host a confirmed booking was cancelled because the invitee's
  request to move it lapsed unanswered.
  """
  @spec handle_reschedule_request_expired(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_request_expired(%{"meeting_id" => meeting_id}) do
    MeetingEmails.with_meeting(meeting_id, "reschedule request expired", fn meeting ->
      send_reschedule_request_expired(meeting)
    end)
  end

  defp send_reschedule_request_expired(
         %{status: "expired", first_announced_at: %DateTime{}} = meeting
       ) do
    locale = RecipientLocale.locale_for_user_id(meeting.organizer_user_id)

    case Config.email_service_module().send_reschedule_request_expired(meeting, locale) do
      {:ok, _sent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_reschedule_request_expired(meeting) do
    Logger.info("Skipping reschedule request expired - not a lapsed reschedule",
      meeting_id: meeting.id,
      status: meeting.status
    )

    {:discard, "Meeting #{meeting.status}"}
  end

  defp send_nudge(meeting) do
    case send_approval_request(:nudge, meeting, Config.email_service_module()) do
      {:ok, _sent} -> stamp_nudge_sent(meeting)
      {:error, reason} -> {:error, reason}
    end
  end

  # The nudge is already on the wire by this point. A retriable error here
  # would make Oban re-run the whole job and resend it, so a stamp failure is
  # logged and swallowed as :ok rather than propagated — a missed stamp is
  # recoverable; a duplicate nudge is not.
  defp stamp_nudge_sent(meeting) do
    case MeetingQueries.mark_approval_nudge_sent(meeting) do
      {:ok, _meeting} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to mark approval nudge as sent after a successful send",
          meeting_id: meeting.id,
          error: LogFormat.reason(reason)
        )

        :ok
    end
  end

  defp send_approval_request(variant, meeting, service, email_opts \\ [])

  defp send_approval_request(variant, meeting, service, []) do
    urls = MeetingLinks.approval_urls(ApprovalToken.sign(meeting))
    service.send_booking_approval_request(variant, meeting, urls, host_locale(meeting))
  end

  defp send_approval_request(variant, meeting, service, email_opts) do
    urls = MeetingLinks.approval_urls(ApprovalToken.sign(meeting))

    service.send_booking_approval_request(
      variant,
      meeting,
      urls,
      host_locale(meeting),
      email_opts
    )
  end

  # The host reads their mail in their own language, not the invitee's, and
  # without an explicit choice in the same default as their other booking
  # mail — not the instance-wide `default_locale/0`, which is English.
  defp host_locale(meeting), do: RecipientLocale.locale_for_user_id(meeting.organizer_user_id)

  # Every approval email is only meaningful while the request is still open.
  defp with_held_request(meeting_id, action, fun) do
    MeetingEmails.with_meeting(meeting_id, action, fn meeting ->
      if MeetingState.awaiting_approval?(meeting) do
        fun.(meeting)
      else
        Logger.info("Skipping approval email - request already answered",
          meeting_id: meeting_id,
          email_action: action,
          status: meeting.status
        )

        {:discard, "Meeting #{meeting.status}"}
      end
    end)
  end
end
