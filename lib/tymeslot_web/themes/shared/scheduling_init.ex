defmodule TymeslotWeb.Themes.Shared.SchedulingInit do
  @moduledoc """
  Shared initialization helpers for scheduling themes.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]

  alias Phoenix.LiveView
  alias TymeslotWeb.Live.Scheduling.Helpers

  @spec assign_theme_state(LiveView.Socket.t(), String.t()) :: LiveView.Socket.t()
  def assign_theme_state(socket, theme_id) do
    timezone = socket.assigns[:user_timezone]

    today =
      case timezone && DateTime.now(timezone) do
        {:ok, dt} -> DateTime.to_date(dt)
        _other -> Date.utc_today()
      end

    week_start = Date.beginning_of_week(today, :monday)

    socket
    |> assign_base_state()
    |> assign(:theme_id, theme_id)
    |> assign(:duration, nil)
    |> assign(:meeting_type, nil)
    |> assign(:current_year, today.year)
    |> assign(:current_month, today.month)
    |> assign(:current_week_start, week_start)
    |> assign(:month_availability_map, nil)
    |> assign(:availability_status, :not_loaded)
    |> assign(:availability_task, nil)
    |> assign(:availability_task_ref, nil)
    |> Helpers.setup_form_state(%{}, as: :booking)
    |> assign(:client_ip, nil)
    |> assign(:submission_token, nil)
    |> assign_new(:meeting_types, fn -> [] end)
  end

  @spec assign_base_state(LiveView.Socket.t()) :: LiveView.Socket.t()
  def assign_base_state(socket) do
    socket
    |> assign(:current_state, :overview)
    |> assign_new(:username_context, fn -> nil end)
    |> assign_new(:organizer_profile, fn -> nil end)
    |> assign_new(:organizer_user_id, fn -> nil end)
    |> assign(:selected_duration, nil)
    |> assign(:selected_date, nil)
    |> assign(:selected_time, nil)
    |> assign(:available_slots, [])
    |> assign(:loading_slots, false)
    |> assign(:calendar_error, nil)
    |> assign(:timezone_dropdown_open, false)
    |> assign(:language_dropdown_open, false)
    |> assign(:timezone_search, "")
    |> assign(:reschedule_meeting_uid, nil)
    |> assign(:is_rescheduling, false)
    |> assign(:meeting_uid, nil)
    |> assign(:name, "")
    |> assign(:email, "")
    |> assign(:submitting, false)
    |> assign(:submission_processed, false)
  end
end
