defmodule TymeslotWeb.Themes.Shared.SchedulingInit do
  @moduledoc """
  Shared initialization helpers for scheduling themes.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]

  alias Phoenix.LiveView
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine

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
    |> OrganizerHelpers.setup_form_state(%{}, as: :booking)
    |> assign_new(:client_ip, fn -> nil end)
    |> assign(:submission_token, nil)
    |> assign_new(:meeting_types, fn -> [] end)
    # Engine starts empty; it is re-initialised with the meeting type's custom
    # field snapshot in maybe_assign_meeting_type/2 once the organiser is resolved.
    |> assign(:engine, QEngine.init([]))
  end

  # The organizer context (username_context, organizer_profile,
  # organizer_user_id, meeting_types, client_ip) may already have been
  # resolved by the theme dispatcher before it delegates to the theme
  # mount — use assign_new for those keys so the resolved values are
  # passed through instead of being reset and resolved a second time.
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
    # Safe defaults so the confirmation components can always render
    # `@custom_fields_snapshot`/`@custom_field_answers`. The booking
    # submission handler overrides these with the real snapshot/answers on a
    # successful booking; a direct visit to `/:username/thank-you` mounts the
    # confirmation state without going through that handler, so without these
    # defaults the render raises a KeyError.
    |> assign(:custom_fields_snapshot, [])
    |> assign(:custom_field_answers, %{})
  end
end
