defmodule TymeslotWeb.OnboardingLive.SkipCalendarModal do
  @moduledoc """
  Nudge modal shown when the user tries to continue past the calendar step
  without connecting a calendar.

  Tymeslot only really works once a calendar is connected — it checks real
  availability and writes bookings back. This modal gently encourages the user
  to reconsider while still letting them proceed.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the "continue without a calendar?" confirmation modal.
  """
  attr :show, :boolean, required: true

  @spec skip_calendar_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def skip_calendar_modal(assigns) do
    ~H"""
    <CoreComponents.modal
      id="skip-calendar-modal"
      show={@show}
      on_cancel={JS.push("hide_skip_calendar_modal")}
      size={:medium}
    >
      <:header>
        <div class="flex items-center gap-4">
          <div class="w-12 h-12 bg-turquoise-50 rounded-2xl flex items-center justify-center border border-turquoise-100">
            <CoreComponents.icon name="hero-calendar-days" class="w-6 h-6 text-turquoise-600" />
          </div>
          Continue without a calendar?
        </div>
      </:header>

      <p class="text-tymeslot-600 font-medium text-token-lg leading-relaxed">
        Tymeslot is built around your calendar. Once it's connected, we read your real
        availability so you're never double-booked and write every new booking back
        automatically — that's what makes Tymeslot worthwhile.
      </p>
      <p class="mt-3 text-tymeslot-500 text-token-base leading-relaxed">
        Without a connected calendar you'll have to manage clashes yourself. You can
        still carry on and connect one later from your dashboard.
      </p>

      <:footer>
        <div class="flex flex-row gap-3">
          <CoreComponents.action_button
            variant={:outline}
            phx-click="confirm_skip_calendar"
            class="flex-1 py-3"
          >
            Continue without one
          </CoreComponents.action_button>
          <CoreComponents.action_button
            variant={:primary}
            phx-click="hide_skip_calendar_modal"
            class="flex-1 py-3"
          >
            Connect a calendar
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
