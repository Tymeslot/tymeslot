defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent do
  @moduledoc """
  Quill theme component for the booking/form step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.Helpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SecurityFields

  import TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
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
  def handle_event("back_step", _params, socket) do
    send(self(), {:step_event, :booking, :back_step, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div data-locale={@locale}>
      <.page_layout
        show_steps={true}
        current_step={3}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="container stack flex-1">
          <div class="flex-1 flex items-center justify-center px-4 py-4">
            <div class="w-full max-w-3xl">
              <.glass_morphism_card class="booking-form-card">
                <div class="p-4 md:p-6 lg:p-8">
                  <.section_header
                    level={2}
                    class="mb-4"
                    title_class="section-header text-2xl md:text-3xl lg:text-4xl"
                  >
                    {gettext("Enter Your Details")}
                  </.section_header>

                  <p class="text-quill-primary text-base md:text-lg lg:text-xl mb-4">
                    <%= if @organizer_profile do %>
                      {gettext("You're booking a %{duration} meeting with %{name}",
                        duration: if(@meeting_type, do: LocalizationHelpers.format_duration(@meeting_type.duration_minutes), else: DateTimeUtils.format_duration(@duration)),
                        name: get_organizer_name(@organizer_profile, @username_context))}
                    <% else %>
                      {gettext("You're booking a %{duration} meeting",
                        duration: if(@meeting_type, do: LocalizationHelpers.format_duration(@meeting_type.duration_minutes), else: DateTimeUtils.format_duration(@duration)))}
                    <% end %>
                  </p>

                  <p class="text-quill-secondary text-xs md:text-sm mb-6">
                    {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
                  </p>

                  <.form
                    :let={f}
                    for={@form}
                    as={:booking}
                    phx-change="validate"
                    phx-submit="submit"
                    phx-target={@myself}
                    data-testid="booking-form"
                    class="space-y-2"
                    id="booking-form"
                    {SecurityFields.recaptcha_form_attrs("booking_form", "booking")}
                  >
                    <SecurityFields.honeypot_field id_prefix="booking" param_root="booking" />

                    <.input
                      field={f[:name]}
                      label={gettext("Your Name")}
                      placeholder={gettext("John Doe")}
                      required
                      phx-debounce="blur"
                      phx-blur="field_blur"
                      phx-value-field="name"
                      phx-target={@myself}
                    />

                    <.input
                      field={f[:email]}
                      label={gettext("Email Address")}
                      type="email"
                      placeholder={gettext("john@example.com")}
                      required
                      phx-debounce="blur"
                      phx-blur="field_blur"
                      phx-value-field="email"
                      phx-target={@myself}
                    />

                    <.input
                      field={f[:message]}
                      type="textarea"
                      label={gettext("Additional Message (Optional)")}
                      placeholder={gettext("Let me know what you'd like to discuss...")}
                      rows={3}
                      phx-debounce="blur"
                      phx-blur="field_blur"
                      phx-value-field="message"
                      phx-target={@myself}
                    />

                    <SecurityFields.recaptcha_fields id_prefix="booking" param_root="booking" />

                    <div class="cluster cluster-xs mt-3">
                      <.action_button
                        type="button"
                        phx-click="back_step"
                        phx-target={@myself}
                        data-testid="back-step"
                        variant={:secondary}
                        disabled={@submitting}
                        class="flex-1"
                      >
                        ← {gettext("back")}
                      </.action_button>

                      <.loading_button
                        type="submit"
                        id="submit-booking-button"
                        loading={@submitting}
                        loading_text={gettext("Verifying...")}
                        disabled={!Helpers.form_valid?(@form)}
                        data-testid="submit-booking"
                        class="flex-1"
                        title={get_submit_title(@submitting, @form)}
                      >
                        {if @is_rescheduling, do: gettext("reschedule_meeting"), else: gettext("book_meeting")} 🎆
                      </.loading_button>
                    </div>
                  </.form>
                </div>
              </.glass_morphism_card>
            </div>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end

  # Helper functions
  defp get_organizer_name(organizer_profile, username_context) do
    organizer_profile.user.name || organizer_profile.full_name || username_context
  end

  defp get_submit_title(submitting, form) do
    cond do
      submitting -> gettext("Verifying slot availability and creating your meeting...")
      !Helpers.form_valid?(form) -> gettext("Please fill in all required fields")
      true -> gettext("Click to schedule your meeting")
    end
  end
end
