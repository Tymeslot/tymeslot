defmodule Tymeslot.Workers.EmailWorkerHandlers.GuestEmails do
  @moduledoc """
  Email job handlers for a meeting's guests: inviting the guests a host adds
  after the booking was made, and the per-guest send that booking
  confirmations share.
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

  # The meeting was cancelled, moved or started after the guests were added.
  @meeting_closed "Meeting no longer open to guests"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason), do: reason == @meeting_closed

  @doc """
  Invites the guests a host added after the booking was made.

  The job names its guests, and only those of them still without
  `confirmation_sent_at` are sent to: the guests already on the meeting hear
  nothing, and a retry does not repeat a send that succeeded. A failed send
  is returned as an error so Oban retries it; a guest the provider rejects
  outright is not, since no retry can reach them. A meeting that has since
  been cancelled, moved or started is discarded rather than announced.
  """
  @spec handle_guest_invitations(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_guest_invitations(%{"meeting_id" => meeting_id, "guest_ids" => guest_ids}) do
    MeetingEmails.with_meeting(meeting_id, "guest invitations", fn meeting ->
      if Guests.invitations_open?(meeting) do
        invite_added_guests(meeting, guest_ids)
      else
        Logger.info("Skipping guest invitations for a meeting closed to guests",
          meeting_id: meeting_id,
          status: meeting.status
        )

        {:discard, @meeting_closed}
      end
    end)
  end

  @doc """
  Sends each of `guests` their invitation and returns each send's result.

  Each guest is claimed before it is sent to (`GuestQueries.claim_confirmation/2`
  stamps `confirmation_sent_at` only while it is unset), because two jobs can
  hold the same unsent guest: the booking's confirmation job, still pending or
  retrying, and the invitation job for a guest the host added meanwhile. Only
  the job that wins the claim sends; the other gets `{:ok, :already_sent}` for
  that guest. A send that fails releases the claim, so the guest is unsent
  again for the next retry.

  As with `Tymeslot.Workers.DeliveryClaims`, a node stopping between the claim
  and the send loses that one invitation rather than risking two.
  """
  @spec send_to_guests(list(), map(), map(), module()) :: [term()]
  def send_to_guests(guests, meeting, appointment_details, email_service) do
    Enum.map(guests, fn guest ->
      claimed_at = DateTime.utc_now(:second)

      case GuestQueries.claim_confirmation(guest, claimed_at) do
        :claimed ->
          send_claimed(guest, claimed_at, meeting, appointment_details, email_service)

        :already_claimed ->
          {:ok, :already_sent}
      end
    end)
  end

  defp send_claimed(guest, claimed_at, meeting, appointment_details, email_service) do
    details = GuestNotifications.guest_details(appointment_details, guest)

    result =
      try do
        email_service.send_guest_confirmation(guest.email, details)
      catch
        kind, reason ->
          GuestQueries.release_confirmation_claim(guest, claimed_at)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case result do
      {:ok, _result} = sent ->
        sent

      other ->
        GuestQueries.release_confirmation_claim(guest, claimed_at)

        Logger.error("Guest confirmation email failed",
          meeting_id: meeting.id,
          guest_email: guest.email,
          result: LogFormat.reason(other)
        )

        other
    end
  end

  defp invite_added_guests(meeting, guest_ids) do
    case GuestQueries.list_unsent_by_ids(meeting.id, guest_ids) do
      [] ->
        :ok

      guests ->
        results =
          send_to_guests(
            guests,
            meeting,
            AppointmentBuilder.from_meeting(meeting),
            Config.email_service_module()
          )

        case Enum.reject(results, &settled?/1) do
          [] ->
            :ok

          failures ->
            {:error,
             DeliveryOutcome.first_actionable(failures) || "Failed to send guest invitations"}
        end
    end
  end

  # Delivered, or rejected outright by the provider: either way, retrying
  # the job cannot change the outcome for this guest.
  defp settled?({:ok, _result}), do: true
  defp settled?({:error, {:recipient_rejected, _reason}}), do: true
  defp settled?(_result), do: false
end
