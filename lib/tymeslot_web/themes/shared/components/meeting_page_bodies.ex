defmodule TymeslotWeb.Themes.Shared.Components.MeetingPageBodies do
  @moduledoc """
  Theme-neutral bodies of the meeting pages (cancel, and its kept state;
  reschedule; cancel-confirmed), for a theme that takes its pages from
  `Shared.DefaultPages`. The markup carries `manage-page__*` classes only,
  styled in `scheduling/shared/components/manage-pages.css`, and sends the
  events the dispatcher handles: `cancel_meeting` and `keep_meeting`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]
  import TymeslotWeb.Themes.Shared.Components.MeetingDetails, only: [meeting_detail_rows: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Shared.PathHandlers

  attr :meeting, :map, required: true
  attr :organizer_profile, :map, default: nil
  attr :locale, :string, required: true
  attr :loading, :boolean, default: false
  attr :meeting_kept, :boolean, default: false

  @spec cancel(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel(%{meeting_kept: true} = assigns) do
    ~H"""
    <.heading icon="hero-check-circle" tone="success">
      <:title>{dgettext("booking_manage", "Meeting Confirmed")}</:title>
      {dgettext("booking_manage", "Great! Your meeting is still scheduled as planned.")}
    </.heading>
    <.details meeting={@meeting} organizer_profile={@organizer_profile} locale={@locale}>
      {dgettext("booking_manage", "Meeting Details")}
    </.details>
    <p class="manage-page__muted">
      {dgettext("booking_manage", "We look forward to seeing you at the scheduled time.")}
    </p>
    <div class="manage-page__actions">
      <button
        type="button"
        class="manage-page__button manage-page__button--primary"
        phx-click={JS.navigate("/")}
      >
        {dgettext("booking_manage", "Done")}
      </button>
    </div>
    """
  end

  def cancel(assigns) do
    ~H"""
    <.heading icon="hero-x-circle" tone="danger">
      <:title>{dgettext("booking_manage", "Cancel Appointment")}</:title>
      {dgettext("booking_manage", "Are you sure you want to cancel this appointment?")}
    </.heading>
    <.details meeting={@meeting} organizer_profile={@organizer_profile} locale={@locale}>
      {dgettext("booking_manage", "Meeting Details")}
    </.details>
    <p class="manage-page__notice manage-page__notice--danger">
      {dgettext("booking_manage", "A cancellation email will be sent to all participants")}
    </p>
    <div class="manage-page__actions">
      <button
        type="button"
        class="manage-page__button manage-page__button--danger"
        phx-click="cancel_meeting"
        data-testid="cancel-meeting"
        disabled={@loading}
      >
        {if @loading,
          do: dgettext("booking_manage", "Cancelling..."),
          else: dgettext("booking_manage", "Yes, Cancel Meeting")}
      </button>
      <button
        type="button"
        class="manage-page__button manage-page__button--secondary"
        phx-click="keep_meeting"
        data-testid="keep-meeting"
        disabled={@loading}
      >
        {dgettext("booking_manage", "Keep Meeting")}
      </button>
    </div>
    """
  end

  attr :meeting, :map, required: true
  attr :organizer_profile, :map, default: nil
  attr :locale, :string, required: true
  attr :meeting_uid, :string, default: nil, doc: "the meeting to move, for the booking page link"

  @spec reschedule(map()) :: Phoenix.LiveView.Rendered.t()
  def reschedule(assigns) do
    assigns = assign(assigns, :booking_path, PathHandlers.organizer_scheduling_path(assigns))

    ~H"""
    <.heading icon="hero-arrow-path" tone="primary">
      <:title>{dgettext("booking_manage", "Reschedule Appointment")}</:title>
      {dgettext("booking_manage", "Select a new time for your meeting")}
    </.heading>
    <.details meeting={@meeting} organizer_profile={@organizer_profile} locale={@locale}>
      {dgettext("booking_manage", "Current Meeting")}
    </.details>
    <p class="manage-page__muted">
      {dgettext(
        "booking_manage",
        "Ready to pick a new time? Let's find one that works better for you."
      )}
    </p>
    <div class="manage-page__actions">
      <button
        type="button"
        class="manage-page__button manage-page__button--primary"
        phx-click={JS.navigate(@booking_path)}
        data-testid="reschedule-choose-time"
      >
        {dgettext("booking_manage", "Choose New Time")}
      </button>
    </div>
    """
  end

  attr :meeting, :map, required: true
  attr :organizer_profile, :map, default: nil
  attr :locale, :string, required: true

  @spec cancel_confirmed(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_confirmed(assigns) do
    ~H"""
    <.heading icon="hero-check-circle" tone="success">
      <:title>{dgettext("booking_manage", "Meeting Cancelled")}</:title>
      {dgettext("booking_manage", "Your meeting has been successfully cancelled.")}
    </.heading>
    <.details meeting={@meeting} organizer_profile={@organizer_profile} locale={@locale}>
      {dgettext("booking_manage", "Meeting Details")}
    </.details>
    <p class="manage-page__notice manage-page__notice--success">
      {dgettext("booking_manage", "Cancellation emails have been sent to all participants.")}
    </p>
    <div class="manage-page__actions">
      <button
        type="button"
        class="manage-page__button manage-page__button--primary"
        phx-click={JS.navigate("/")}
      >
        {dgettext("booking_manage", "Schedule a New Meeting")}
      </button>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :tone, :string, required: true, values: ~w(success danger primary)
  slot :title, required: true
  slot :inner_block, required: true

  defp heading(assigns) do
    ~H"""
    <div class="manage-page__header">
      <.status_icon icon={@icon} tone={@tone} />
      <h1 class="manage-page__title">{render_slot(@title)}</h1>
      <p class="manage-page__lead">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :tone, :string, required: true, values: ~w(success danger primary)

  @doc """
  A default page's status icon above its title, tinted by `tone`. The
  payment pages (`Shared.DefaultPages`) show it too.
  """
  @spec status_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def status_icon(assigns) do
    ~H"""
    <.icon name={@icon} class={"manage-page__icon manage-page__icon--#{@tone}"} />
    """
  end

  attr :meeting, :map, required: true
  attr :organizer_profile, :map, default: nil
  attr :locale, :string, required: true
  slot :inner_block, required: true

  defp details(assigns) do
    ~H"""
    <section class="manage-page__details">
      <div class="manage-page__details-header">
        <h2 class="manage-page__details-title">{render_slot(@inner_block)}</h2>
        <span class="manage-page__duration">
          {dgettext("booking_manage", "%{minutes} min", minutes: @meeting.duration)}
        </span>
      </div>
      <.meeting_detail_rows
        start_time={@meeting.start_time}
        timezone={@meeting.attendee_timezone}
        organizer_profile={@organizer_profile}
        locale={@locale}
        organizer_name={@meeting.organizer_name}
      />
    </section>
    """
  end
end
