defmodule TymeslotWeb.BookingVerificationLive.View do
  @moduledoc """
  Markup for the page an attendee confirms a held booking on.

  Until the socket connects the page only says it is checking the link
  (`:loading`). Then the booking is either still held (`:awaiting`, or `:failed` when a
  confirmation could not be completed and may be tried again), or the page
  reports where it ended up: confirmed, sent to the host for approval,
  already confirmed, released by the attendee, expired, or a link we cannot
  read. Times are shown in the attendee's own timezone, since the attendee is
  the one reading.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :state, :atom, required: true
  attr :meeting, :map, default: nil
  attr :rebook_path, :string, default: nil

  # The booking's language, set once the token is read. The token read waits
  # for the connected render, by which time the root layout's `<html lang>`
  # is already fixed, so the page declares its own language here.
  attr :locale, :string, default: nil

  @spec page(map()) :: Phoenix.LiveView.Rendered.t()
  def page(assigns) do
    ~H"""
    <div lang={@locale} class="min-h-screen bg-tymeslot-50 px-4 py-12">
      <div class="mx-auto w-full max-w-2xl">
        <.glass_morphism_card>
          <div class="p-6 sm:p-8">
            <.held_booking :if={@state in [:awaiting, :failed]} meeting={@meeting} />
            <.outcome
              :if={@state not in [:awaiting, :failed]}
              state={@state}
              meeting={@meeting}
              rebook_path={@rebook_path}
            />
          </div>
        </.glass_morphism_card>
      </div>
    </div>
    """
  end

  attr :meeting, :map, required: true

  defp held_booking(assigns) do
    ~H"""
    <div>
      <.section_header
        level={1}
        title={dgettext("booking_manage", "Confirm your booking")}
        icon="hero-envelope"
      />

      <div class="mt-6 space-y-4">
        <.detail_line icon="hero-tag" label={dgettext("booking_manage", "Meeting")}>
          {title(@meeting)}
        </.detail_line>
        <.detail_line icon="hero-calendar" label={dgettext("booking_manage", "When")}>
          {LocalizationHelpers.format_meeting_datetime(
            @meeting.start_time,
            @meeting.attendee_timezone
          )}
        </.detail_line>
        <.detail_line
          :if={@meeting.organizer_name not in [nil, ""]}
          icon="hero-user"
          label={dgettext("booking_manage", "With")}
        >
          {@meeting.organizer_name}
        </.detail_line>
      </div>

      <.info_box :if={@meeting.verification_deadline_at} variant={:info} class="mt-6">
        {dgettext("booking_manage", "Your booking is held until %{time}.",
          time:
            LocalizationHelpers.format_meeting_datetime(
              @meeting.verification_deadline_at,
              @meeting.attendee_timezone
            )
        )}
      </.info_box>

      <div class="mt-8 flex flex-wrap gap-3">
        <.action_button
          variant={:primary}
          phx-click="confirm"
          phx-disable-with={dgettext("booking_manage", "Confirming…")}
          data-testid="confirm-booking"
        >
          {dgettext("booking_manage", "Confirm booking")}
        </.action_button>

        <.action_button
          variant={:outline}
          phx-click="release"
          phx-disable-with={dgettext("booking_manage", "Cancelling…")}
          data-testid="release-booking"
        >
          {dgettext("booking_manage", "I didn't make this booking")}
        </.action_button>
      </div>
    </div>
    """
  end

  attr :state, :atom, required: true
  attr :meeting, :map, default: nil
  attr :rebook_path, :string, default: nil

  defp outcome(assigns) do
    ~H"""
    <div class="text-center">
      <Containers.icon_badge icon={outcome_icon(@state)} />

      <h1 class="display-md mt-6">{outcome_title(@state)}</h1>

      <p class="mt-3 text-token-base text-tymeslot-600">
        {outcome_body(@state, @meeting)}
      </p>

      <div :if={@state == :expired and @rebook_path} class="mt-8 flex justify-center">
        <.action_link href={@rebook_path} variant={:primary} data-testid="rebook-link">
          {dgettext("booking_manage", "Book again")}
        </.action_link>
      </div>
    </div>
    """
  end

  defp title(%{title: title}) when is_binary(title) and title != "", do: title
  defp title(%{meeting_type: type}) when is_binary(type) and type != "", do: type
  defp title(_meeting), do: dgettext("booking_manage", "Meeting")

  defp outcome_icon(state) when state in [:verified, :already_verified], do: "hero-check-circle"
  defp outcome_icon(:verified_request), do: "hero-paper-airplane"
  defp outcome_icon(:released), do: "hero-x-circle"
  defp outcome_icon(:expired), do: "hero-clock"
  defp outcome_icon(:loading), do: "hero-envelope"
  defp outcome_icon(_state), do: "hero-question-mark-circle"

  defp outcome_title(:verified), do: dgettext("booking_manage", "Your booking is confirmed")

  defp outcome_title(:verified_request),
    do: dgettext("booking_manage", "Your request has been sent")

  defp outcome_title(:already_verified),
    do: dgettext("booking_manage", "This booking is already confirmed")

  defp outcome_title(:released), do: dgettext("booking_manage", "Booking cancelled")
  defp outcome_title(:expired), do: dgettext("booking_manage", "This booking has expired")
  defp outcome_title(:loading), do: dgettext("booking_manage", "Checking your link…")
  defp outcome_title(_state), do: dgettext("booking_manage", "This link is not valid")

  defp outcome_body(:verified, _meeting) do
    dgettext("booking_manage", "We have emailed you the details and a calendar invitation.")
  end

  defp outcome_body(:verified_request, meeting) do
    dgettext(
      "booking_manage",
      "%{organizer} will confirm or decline it. We have emailed you the details.",
      organizer: organizer(meeting)
    )
  end

  defp outcome_body(:already_verified, _meeting) do
    dgettext("booking_manage", "Check your inbox for the confirmation email.")
  end

  defp outcome_body(:released, _meeting) do
    dgettext("booking_manage", "The booking was cancelled and the time released.")
  end

  defp outcome_body(:expired, _meeting) do
    dgettext(
      "booking_manage",
      "This booking is no longer available, so the time was released."
    )
  end

  defp outcome_body(:loading, _meeting) do
    dgettext("booking_manage", "This only takes a moment.")
  end

  defp outcome_body(_state, _meeting) do
    dgettext("booking_manage", "It may be incomplete or out of date.")
  end

  defp organizer(%{organizer_name: name}) when is_binary(name) and name != "", do: name
  defp organizer(_meeting), do: dgettext("booking_manage", "The organiser")
end
