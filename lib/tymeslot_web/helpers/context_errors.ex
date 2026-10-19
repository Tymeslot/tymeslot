defmodule TymeslotWeb.Helpers.ContextErrors do
  @moduledoc """
  Form copy for the error atoms a context returns: each maps to the field the
  form shows it against.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Converts context error atoms to user-friendly error messages.
  """
  @spec format_context_error(atom() | any()) :: map()
  def format_context_error(:video_integration_required) do
    %{
      video_integration: [
        dgettext("dashboard_meeting_form", "Please select a video provider for video meetings")
      ]
    }
  end

  def format_context_error(:invalid_video_integration) do
    %{
      video_integration: [
        dgettext("dashboard_meeting_form", "Selected video provider is invalid or inactive")
      ]
    }
  end

  def format_context_error(:invalid_availability_schedule) do
    %{
      availability_schedule: [
        dgettext("dashboard_meeting_form", "Selected schedule is not one of yours")
      ]
    }
  end

  def format_context_error(:invalid_venue) do
    %{
      base: [
        dgettext("dashboard_meeting_form", "A selected location is not one of yours")
      ]
    }
  end

  def format_context_error(:invalid_duration) do
    %{duration: [dgettext("dashboard_meeting_form", "Duration must be a valid number")]}
  end

  def format_context_error(:calendar_integration_required) do
    %{
      calendar_integration: [
        dgettext("dashboard_meeting_form", "Please select a calendar account")
      ]
    }
  end

  def format_context_error(:calendar_integration_invalid) do
    %{
      calendar_integration: [
        dgettext("dashboard_meeting_form", "Selected calendar account is invalid")
      ]
    }
  end

  def format_context_error(:target_calendar_required) do
    %{target_calendar: [dgettext("dashboard_meeting_form", "Please select a target calendar")]}
  end

  def format_context_error(:target_calendar_invalid) do
    %{
      target_calendar: [
        dgettext("dashboard_meeting_form", "Selected calendar is not available for this account")
      ]
    }
  end

  def format_context_error(:no_writable_calendars) do
    %{
      target_calendar: [
        dgettext(
          "dashboard_meeting_form",
          "None of the calendars you selected for this account can accept bookings. Update your calendar selection in Integration settings, or choose a different account."
        )
      ]
    }
  end

  def format_context_error(:invalid_price) do
    %{price_cents: [dgettext("dashboard_meeting_form", "Enter a valid price")]}
  end

  def format_context_error(:group_bookings_not_allowed) do
    %{max_participants: [group_bookings_not_allowed_message()]}
  end

  def format_context_error(:invalid_approval_window) do
    %{
      approval_window_hours: [
        dgettext(
          "dashboard_meeting_form",
          "Enter a whole number of hours, or leave blank to use the default."
        )
      ]
    }
  end

  # The owner's account, or the calendar the meeting type books into, went
  # while the save was running.
  def format_context_error(:not_found) do
    %{
      base: [
        dgettext(
          "dashboard_meeting_form",
          "The calendar this meeting type books into is no longer available. Reload the page and try again."
        )
      ]
    }
  end

  def format_context_error(error) when is_atom(error) do
    %{base: [format_generic_error(error)]}
  end

  def format_context_error(error) do
    %{base: [to_string(error)]}
  end

  @doc """
  Why a host may not enable group bookings, or raise a group type's limit.
  """
  @spec group_bookings_not_allowed_message() :: String.t()
  def group_bookings_not_allowed_message do
    dgettext("dashboard_meeting_form", "Group bookings are not included in your current plan.")
  end

  defp format_generic_error(error) when is_atom(error) do
    error
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
