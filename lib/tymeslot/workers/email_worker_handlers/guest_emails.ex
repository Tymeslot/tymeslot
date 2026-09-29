defmodule Tymeslot.Workers.EmailWorkerHandlers.GuestEmails do
  @moduledoc """
  Email job handlers and the shared send loops for a meeting's guests: a
  booking's guests are invited alongside its confirmation and reminded
  alongside its reminders, and the guests a host adds after the booking was
  made are invited by a job of their own.

  Split out of `Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails` so the
  solo and group handlers (`GroupMeetingEmails`) share one send loop. Each
  guest is stamped on success, so a retry only reaches the guests a previous
  run missed, and a failed guest send never fails the job that made it.
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Utils.ReminderUtils
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
  Invites whichever of the meeting's guests a previous confirmation run did
  not reach. Builds the payload only when there is somebody to send to, so
  the already-sent path stays one cheap query.
  """
  @spec invite_missed(MeetingSchema.t()) :: :ok
  def invite_missed(meeting) do
    case GuestQueries.list_unsent_for_meeting(meeting.id) do
      [] ->
        :ok

      unsent ->
        send_confirmations(
          unsent,
          meeting,
          AppointmentBuilder.from_meeting(meeting),
          Config.email_service_module()
        )
    end
  end

  @doc """
  Sends each of `guests` their invitation and returns each send's result.

  A guest is stamped with `confirmation_sent_at` only once their invitation
  has gone, so whatever failed is still unsent for the next run.
  """
  @spec send_to_guests([GuestSchema.t()], MeetingSchema.t(), map(), module()) :: [term()]
  def send_to_guests(guests, meeting, appointment_details, email_service) do
    Enum.map(guests, fn guest ->
      details = GuestNotifications.guest_details(appointment_details, guest)

      case email_service.send_guest_confirmation(guest.email, details) do
        {:ok, _result} = sent ->
          GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))
          sent

        other ->
          Logger.error("Guest confirmation email failed",
            meeting_id: meeting.id,
            guest_email: guest.email,
            result: LogFormat.reason(other)
          )

          other
      end
    end)
  end

  @doc """
  Sends every guest in `guests` their confirmation through `send_to_guests/4`
  for a caller whose own result the guests must never change: failures are
  logged and the guest left unsent for the next run.

  Shared by `MeetingEmails` and `GroupMeetingEmails`: the loop is identical
  for a meeting's guests and one participant's guests, they only differ in how
  `guests` was queried (`GuestQueries.list_unsent_for_meeting/1` vs
  `GuestQueries.list_unsent_for_participant/1`).
  """
  @spec send_confirmations([GuestSchema.t()], MeetingSchema.t(), map(), module()) :: :ok
  def send_confirmations(guests, meeting, appointment_details, email_service) do
    _results = send_to_guests(guests, meeting, appointment_details, email_service)
    :ok
  end

  @doc """
  Reminds the meeting's guests for one configured offset, stamping each guest
  per offset so a retry after a partial send re-emails only the guests it has
  not reached. Failures are logged and never change the caller's result.
  """
  @spec send_reminders(MeetingSchema.t(), map(), term(), term()) :: :ok
  def send_reminders(meeting, appointment_details, reminder_value, reminder_unit) do
    value = ReminderUtils.parse_reminder_value(reminder_value)
    unit = ReminderUtils.normalize_reminder_unit(reminder_unit)
    email_service = Config.email_service_module()

    meeting.id
    |> GuestQueries.list_for_reminder(value, unit)
    |> Enum.each(fn guest ->
      details = GuestNotifications.guest_details(appointment_details, guest)

      case email_service.send_guest_reminder(guest.email, details) do
        {:ok, _result} ->
          GuestQueries.mark_reminder_sent(guest, value, unit)

        other ->
          Logger.error("Guest reminder email failed",
            meeting_id: meeting.id,
            guest_id: guest.id,
            result: LogFormat.reason(other)
          )
      end
    end)
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
