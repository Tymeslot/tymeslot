defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.BookingComponent do
  @moduledoc """
  Rhythm theme component for the booking/contact form step.
  Updated to use form struct and shared patterns.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Live.Scheduling.Helpers
  alias TymeslotWeb.Themes.Rhythm.Shared.OrganizerHeader
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"booking" => booking_params}, socket) do
    send(self(), {:step_event, :booking, :validate, booking_params})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("field_blur", %{"field" => field_name}, socket) do
    send(self(), {:step_event, :booking, :field_blur, field_name})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("submit", %{"booking" => booking_params}, socket) do
    # Set submitting state immediately for instant UI feedback
    socket = assign(socket, :submitting, true)
    send(self(), {:step_event, :booking, :submit, booking_params})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("prev_slide", _params, socket) do
    send(self(), {:step_event, :booking, :back_step, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="scheduling-box" data-locale={@locale}>
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content booking-slide">
            <!-- Organizer Header -->
            <div class="schedule-header">
              <OrganizerHeader.organizer_header_small
                organizer_profile={@organizer_profile}
                meeting_type={@meeting_type}
                selected_duration={@duration}
              />
            </div>

    <!-- Meeting Summary -->
            <div class="meeting-summary compact">
              <div class="summary-row">
                <div class="summary-item">
                  <.icon name="hero-calendar" class="summary-icon hero-icon hero-icon--md" />
                  <div>
                    <div class="summary-value">{LocalizationHelpers.format_date(@selected_date)}</div>
                    <div class="summary-label">{@selected_time || gettext("No time selected")}</div>
                  </div>
                </div>
                <div class="summary-item">
                  <.icon name="hero-globe-alt" class="summary-icon hero-icon hero-icon--md" />
                  <div>
                    <div class="summary-value">
                      {TimezoneUtils.format_timezone(@user_timezone || "America/New_York")}
                    </div>
                    <div class="summary-label">
                      <%= if @meeting_type do %>
                        {LocalizationHelpers.format_duration(@meeting_type.duration_minutes)} {gettext("meeting")}
                      <% else %>
                        {LocalizationHelpers.format_duration(@selected_duration)} {gettext("meeting")}
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            </div>

    <!-- Contact Form -->
            <.form
              :let={f}
              for={@form}
              phx-submit="submit"
              phx-change="validate"
              phx-target={@myself}
              data-testid="booking-form"
              class="booking-form"
              as={:booking}
            >
              <.input
                field={f[:name]}
                label={gettext("name")}
                placeholder={gettext("enter_full_name")}
                phx-blur="field_blur"
                phx-value-field="name"
                phx-target={@myself}
              />

              <.input
                field={f[:email]}
                label={gettext("email")}
                type="email"
                placeholder={gettext("enter_email")}
                phx-blur="field_blur"
                phx-value-field="email"
                phx-target={@myself}
              />

              <.input
                field={f[:message]}
                type="textarea"
                label={gettext("message_optional")}
                placeholder={gettext("add_details")}
                rows={4}
                phx-blur="field_blur"
                phx-value-field="message"
                phx-target={@myself}
              />

    <!-- Navigation -->
              <div class="slide-actions horizontal">
                <button
                  type="button"
                  class="prev-button"
                  phx-click="prev_slide"
                  phx-target={@myself}
                  data-testid="back-step"
                  disabled={@submitting}
                >
                  ← {gettext("back")}
                </button>
                <button
                  type="submit"
                  class="submit-button"
                  data-testid="submit-booking"
                  disabled={@submitting || !Helpers.form_valid?(@form)}
                >
                  <%= if @submitting do %>
                    <svg
                      class="loading-spinner icon-sm"
                      xmlns="http://www.w3.org/2000/svg"
                      fill="none"
                      viewBox="0 0 24 24"
                    >
                      <circle
                        class="loading-spinner-track"
                        cx="12"
                        cy="12"
                        r="10"
                        stroke="currentColor"
                        stroke-width="4"
                      >
                      </circle>
                      <path
                        class="loading-spinner-path"
                        fill="currentColor"
                        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                      >
                      </path>
                    </svg>
                    <span>{gettext("Verifying...")}</span>
                  <% else %>
                    {if @is_rescheduling, do: gettext("reschedule_meeting"), else: gettext("submit")}
                  <% end %>
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
