defmodule Tymeslot.Workers.EmailWorkerHandlers.BookingApprovalEmails do
  @moduledoc """
  Handles the approval-gated booking email actions: the request emails sent
  when a host must approve a booking, the mid-window nudge, and the outcome
  email sent once a request is declined or expires.
  """

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

  @doc """
  Sends the invitee's acknowledgement and the host's request.

  The two are independent notifications to different people, so neither
  gates the other: both are attempted on every execution, and the host leg
  runs whether or not the invitee's acknowledgement succeeded. A permanently
  rejected or slow-to-retry invitee address must never leave the host
  unaware a booking request exists at all.

  Both are guarded on the meeting still being held. A request answered, or
  withdrawn by the invitee, between enqueue and execution must not produce an
  email telling either party it is still open.

  `args["skip_attendee_ack"]` / `args["skip_host_request"]` are set only by
  `retry_failed_leg/3` below, when one leg already went out and only the
  other failed: it requeues a single-leg follow-up so a later Oban retry (of
  either the original job or the follow-up) can never duplicate the leg that
  already succeeded.
  """
  @spec handle_booking_request_emails(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_booking_request_emails(%{"meeting_id" => meeting_id} = args) do
    with_held_request(meeting_id, "booking request emails", fn meeting ->
      send_both_legs(meeting_id, meeting, args)
    end)
  end

  defp send_both_legs(meeting_id, meeting, args) do
    service = Config.email_service_module()

    attendee_status =
      leg_status(Map.get(args, "skip_attendee_ack", false), fn ->
        service.send_booking_request_received(meeting)
      end)

    host_status =
      leg_status(Map.get(args, "skip_host_request", false), fn ->
        send_approval_request(:request, meeting, service)
      end)

    combine_leg_results(meeting_id, attendee_status, host_status)
  end

  # `:skipped` means this leg already succeeded on a prior attempt and this
  # execution deliberately did not re-send it — it must never be treated the
  # same as a fresh failure or success for requeue purposes.
  defp leg_status(true, _send_fun), do: :skipped

  defp leg_status(false, send_fun) do
    case send_fun.() do
      {:ok, _sent} -> :sent
      {:error, reason} -> {:failed, reason}
    end
  end

  defp combine_leg_results(_meeting_id, attendee, host)
       when attendee in [:sent, :skipped] and host in [:sent, :skipped],
       do: :ok

  defp combine_leg_results(meeting_id, :sent, {:failed, reason}) do
    # The invitee's copy just went; a plain whole-job retry would resend it,
    # so requeue a host-only follow-up instead.
    retry_failed_leg(meeting_id, [skip_attendee_ack: true], reason)
  end

  defp combine_leg_results(meeting_id, {:failed, reason}, :sent) do
    # Symmetric case: the host's request just went, only the invitee's
    # acknowledgement failed.
    retry_failed_leg(meeting_id, [skip_host_request: true], reason)
  end

  defp combine_leg_results(_meeting_id, {:failed, reason}, :skipped), do: {:error, reason}
  defp combine_leg_results(_meeting_id, :skipped, {:failed, reason}), do: {:error, reason}

  defp combine_leg_results(_meeting_id, {:failed, attendee_reason}, {:failed, _host_reason}) do
    # Neither leg went out — nothing to protect from duplication, so an
    # ordinary whole-job Oban retry (which reattempts both) is safe.
    {:error, attendee_reason}
  end

  defp retry_failed_leg(meeting_id, skip_opts, reason) do
    case EmailScheduler.schedule_request_emails(meeting_id, skip_opts) do
      :ok ->
        {:discard,
         "One booking request leg already sent; the other failed and was requeued: #{inspect(reason)}"}

      {:error, requeue_reason} ->
        Logger.error("Failed to requeue booking request leg",
          meeting_id: meeting_id,
          error: requeue_reason
        )

        {:error, reason}
    end
  end

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
          error: inspect(reason)
        )

        :ok
    end
  end

  defp send_approval_request(variant, meeting, service) do
    urls = Policy.approval_urls(ApprovalToken.sign(meeting))
    service.send_booking_approval_request(variant, meeting, urls, host_locale(meeting))
  end

  # The host reads their mail in their own language, not the invitee's.
  defp host_locale(%{organizer_user_id: nil}), do: Locales.default_locale()

  defp host_locale(meeting) do
    case Auth.get_user(meeting.organizer_user_id) do
      {:ok, %{locale: locale}} when is_binary(locale) -> locale
      _no_explicit_choice -> Locales.default_locale()
    end
  end

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
