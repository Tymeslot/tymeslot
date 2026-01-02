defmodule TymeslotWeb.Themes.Shared.SchedulingInit do
  @moduledoc """
  Shared initialization helpers for scheduling themes.
  """

  import Phoenix.Component, only: [assign: 3]
  alias Phoenix.LiveView

  @spec assign_base_state(LiveView.Socket.t()) :: LiveView.Socket.t()
  def assign_base_state(socket) do
    socket
    |> assign(:current_state, :overview)
    |> assign(:username_context, nil)
    |> assign(:organizer_profile, nil)
    |> assign(:organizer_user_id, nil)
    |> assign(:selected_duration, nil)
    |> assign(:selected_date, nil)
    |> assign(:selected_time, nil)
    |> assign(:available_slots, [])
    |> assign(:loading_slots, false)
    |> assign(:calendar_error, nil)
    |> assign(:timezone_dropdown_open, false)
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
