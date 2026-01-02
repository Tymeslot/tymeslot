defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent do
  @moduledoc """
  Quill theme component for the booking/form step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Live.Scheduling.Helpers

  import TymeslotWeb.Components.CoreComponents

  @impl true
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl true
  def handle_event("validate", %{"booking" => booking_params}, socket) do
    send(self(), {:step_event, :booking, :validate, booking_params})
    {:noreply, socket}
  end

  @impl true
  def handle_event("field_blur", %{"field" => field_name}, socket) do
    send(self(), {:step_event, :booking, :field_blur, field_name})
    {:noreply, socket}
  end

  @impl true
  def handle_event("submit", %{"booking" => booking_params}, socket) do
    # Set submitting state immediately for instant UI feedback
    socket = assign(socket, :submitting, true)
    send(self(), {:step_event, :booking, :submit, booking_params})
    {:noreply, socket}
  end

  @impl true
  def handle_event("back_step", _params, socket) do
    send(self(), {:step_event, :booking, :back_step, nil})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_layout
        show_steps={true}
        current_step={3}
        duration={@duration}
        username_context={@username_context}
      >
        <div class="container flex-1 flex flex-col">
          <div class="flex-1 flex items-center justify-center px-4 py-4">
            <div class="w-full max-w-3xl">
              <.glass_morphism_card class="booking-form-card">
                <div class="p-4 md:p-6 lg:p-8">
                  <.section_header level={2} class="text-2xl md:text-3xl lg:text-4xl mb-4">
                    Enter Your Details
                  </.section_header>

                  <p
                    class="text-base md:text-lg lg:text-xl mb-4"
                    style="color: rgba(255,255,255,0.85); line-height: 1.5;"
                  >
                    You're booking a
                    <span class="font-semibold" style="color: var(--theme-primary);">
                      {TimezoneUtils.format_duration(@duration)}
                    </span>
                    meeting{if @organizer_profile,
                      do:
                        " with <span class=\"font-semibold\" style=\"color: var(--theme-primary);\">#{get_organizer_name(@organizer_profile, @username_context)}</span>"
                        |> raw}
                  </p>

                  <p class="text-xs md:text-sm mb-6" style="color: rgba(255,255,255,0.7);">
                    {Helpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
                  </p>

                  <.form
                    for={@form}
                    phx-change="validate"
                    phx-submit="submit"
                    phx-target={@myself}
                    class="space-y-2"
                  >
                    <.form_field
                      form={@form}
                      field={:name}
                      label="Your Name"
                      placeholder="John Doe"
                      required={true}
                      touched_fields={@touched_fields}
                      phx-debounce="blur"
                      phx-blur="field_blur"
                      phx-value-field="name"
                      phx-target={@myself}
                    />

                    <.form_field
                      form={@form}
                      field={:email}
                      label="Email Address"
                      type="email"
                      placeholder="john@example.com"
                      required={true}
                      touched_fields={@touched_fields}
                      phx-debounce="blur"
                      phx-blur="field_blur"
                      phx-value-field="email"
                      phx-target={@myself}
                    />

                    <.form_textarea
                      form={@form}
                      field={:message}
                      label="Additional Message (Optional)"
                      placeholder="Let me know what you'd like to discuss..."
                      rows={3}
                      touched_fields={@touched_fields}
                      phx-debounce="blur"
                      phx-blur="field_blur"
                      phx-value-field="message"
                      phx-target={@myself}
                    />

                    <div class="mt-3 flex gap-2">
                      <.action_button
                        type="button"
                        phx-click="back_step"
                        phx-target={@myself}
                        variant={:secondary}
                        class="flex-1"
                      >
                        ← Back
                      </.action_button>

                      <.loading_button
                        type="submit"
                        id="submit-booking-button"
                        loading={@submitting}
                        loading_text="Verifying..."
                        disabled={!Helpers.form_valid?(@form)}
                        class="flex-1"
                        title={get_submit_title(@submitting, @form)}
                      >
                        Schedule Meeting 🎆
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
      submitting -> "Verifying slot availability and creating your meeting..."
      !Helpers.form_valid?(form) -> "Please fill in all required fields"
      true -> "Click to schedule your meeting"
    end
  end
end
