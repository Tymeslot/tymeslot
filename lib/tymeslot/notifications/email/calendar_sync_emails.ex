defmodule Tymeslot.Notifications.Email.CalendarSyncEmails do
  @moduledoc """
  The emails telling a host what their calendar did to a booking: that the
  booking was moved there, outside Tymeslot, or that its calendar event could
  not be written at all.

  Both are raised by calendar sync code, which only schedules them
  (`Tymeslot.Emails.EmailScheduler.schedule_external_booking_change/2`,
  `schedule_calendar_sync_error/2`); these handlers send them from the email
  job, so a failed send is retried rather than lost.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Notifications.Email.MeetingEmails

  # The stored form of `Tymeslot.Emails.Templates.ExternalBookingChange.discrepancy()`,
  # mapped back explicitly rather than with `String.to_existing_atom/1`, so a
  # job can only ever carry one of the two.
  @discrepancies %{"deleted" => :deleted, "modified" => :modified}

  @doc """
  Tells the host that a booking was changed in their external calendar.
  """
  @spec handle_external_booking_change(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_external_booking_change(%{"meeting_id" => meeting_id, "discrepancy" => stored}) do
    case Map.fetch(@discrepancies, stored) do
      {:ok, discrepancy} ->
        MeetingEmails.with_meeting(meeting_id, "external booking change", fn meeting ->
          meeting
          |> Config.email_service_module().send_external_booking_change(
            meeting.organizer_email,
            discrepancy
          )
          |> sent()
        end)

      :error ->
        {:discard, "Unknown discrepancy: #{inspect(stored)}"}
    end
  end

  @doc """
  Tells the calendar's owner that a booking's calendar event could not be
  written. `"error_reason"` is the failure as the email states it.
  """
  @spec handle_calendar_sync_error(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_calendar_sync_error(%{"meeting_id" => meeting_id, "error_reason" => error_reason}) do
    MeetingEmails.with_meeting(meeting_id, "calendar sync error", fn meeting ->
      meeting
      |> Config.email_service_module().send_calendar_sync_error(error_reason)
      |> sent()
    end)
  end

  defp sent({:ok, _result}), do: :ok
  defp sent({:error, _reason} = error), do: error
end
