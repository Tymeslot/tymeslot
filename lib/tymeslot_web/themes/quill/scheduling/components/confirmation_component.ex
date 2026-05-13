defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Quill theme component for the confirmation/thank you step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("schedule_another", _params, socket) do
    send(self(), {:step_event, :confirmation, :schedule_another, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="container flex-1" data-locale={@locale}>
      <.page_layout
        show_steps={true}
        current_step={4}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="stack">
          <div class="confirmation-outer flex-1 flex items-center justify-center">
            <div class="w-full confirmation-container">
              <.glass_morphism_card>
                <div class="confirmation-content">
                  <div class="confirmation-heading-row flex items-center">
                    <div class="flex-shrink-0">
                      <div class="relative">
                        <div class="confirmation-badge rounded-full flex items-center justify-center">
                          <svg
                            class="confirmation-badge-icon text-white"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="3"
                            viewBox="0 0 24 24"
                          >
                            <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
                          </svg>
                        </div>
                        <div class="confirmation-badge-dot absolute rounded-full flex items-center justify-center">
                          <svg
                            class="confirmation-badge-dot-icon text-white"
                            fill="currentColor"
                            viewBox="0 0 20 20"
                          >
                            <path d="M10 2a6 6 0 00-6 6v3.586l-.707.707A1 1 0 004 14h12a1 1 0 00.707-1.707L16 11.586V8a6 6 0 00-6-6zM10 18a3 3 0 01-3-3h6a3 3 0 01-3 3z" />
                          </svg>
                        </div>
                      </div>
                    </div>
                    <div class="flex-1 min-w-0" data-testid="confirmation-heading">
                      <.section_header
                        class="mb-1"
                        title_class="section-header confirmation-title"
                      >
                        <%= if @is_rescheduling do %>
                          {gettext("Meeting Rescheduled!")}
                        <% else %>
                          {gettext("meeting_confirmed")}
                        <% end %>
                      </.section_header>
                      <p class="confirmation-subtitle text-quill-primary">
                        <%= if @is_rescheduling do %>
                          {gettext("%{name}, your meeting %{organizer} has been rescheduled.", name: @name, organizer: get_organizer_text(@organizer_profile))}
                        <% else %>
                          {gettext("%{name}, your meeting %{organizer} is all set.", name: @name, organizer: get_organizer_text(@organizer_profile))}
                        <% end %>
                      </p>
                    </div>
                  </div>

                  <.meeting_details_card title="">
                    <.booking_details
                      date={@selected_date}
                      time={@selected_time}
                      duration={@duration}
                      timezone={@user_timezone}
                      variant={:compact}
                    />

                    <div class="confirmation-border-top mt-3 pt-3 border-t">
                      <div class="confirmation-email-row">
                        <div class="confirmation-icon-wrapper rounded-full center-content">
                          <svg
                            class="confirmation-email-link w-3.5 h-3.5"
                            fill="currentColor"
                            viewBox="0 0 20 20"
                          >
                            <path d="M2.003 5.884L10 9.882l7.997-3.998A2 2 0 0016 4H4a2 2 0 00-1.997 1.884z" />
                            <path d="M18 8.118l-8 4-8-4V14a2 2 0 002 2h12a2 2 0 002-2V8.118z" />
                          </svg>
                        </div>
                        <p class="text-sm text-white">
                          {gettext("Confirmation sent to")}
                          <span class="confirmation-email-link font-semibold">
                            {@email}
                          </span>
                        </p>
                      </div>
                    </div>
                  </.meeting_details_card>

                  <%= if length(@custom_fields_snapshot) > 0 do %>
                    <section class="custom-answers-section">
                      <h3 class="custom-answers-heading">{gettext("Your answers")}</h3>
                      <dl class="custom-answers-list">
                        <%= for d <- @custom_fields_snapshot do %>
                          <div class="custom-answer-row">
                            <dt class="custom-answer-label">{d["label"]}</dt>
                            <dd class="custom-answer-value">
                              {render_answer(d, @custom_field_answers[d["id"]])}
                            </dd>
                          </div>
                        <% end %>
                      </dl>
                    </section>
                  <% end %>

                  <div class="confirmation-actions">
                    <.action_button
                      phx-click="schedule_another"
                      phx-target={@myself}
                      data-testid="schedule-another"
                      class="inline-block"
                    >
                      {gettext("Schedule Another Meeting")}
                    </.action_button>
                  </div>

                  <p class="confirmation-help-text mt-3 text-xs">
                    {gettext("Need to reschedule? Check your confirmation email.")}
                  </p>
                </div>
              </.glass_morphism_card>
            </div>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end

  # ========== MEETING DISPLAY COMPONENTS ==========

  attr :title, :string, default: ""
  slot :inner_block, required: true

  defp meeting_details_card(assigns) do
    ~H"""
    <div class="meeting-details-card">
      <%= if @title && @title != "" do %>
        <h3 class="text-lg font-semibold mb-4 text-purple-900">{@title}</h3>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :date, :string, required: true
  attr :time, :string, required: true
  attr :duration, :string, required: true
  attr :timezone, :string, required: true
  attr :variant, :atom, default: :compact, values: [:compact, :expanded]

  defp booking_details(assigns) do
    grid_class =
      case assigns.variant do
        :expanded -> "booking-details-grid booking-details-grid--expanded"
        _other -> "booking-details-grid"
      end

    assigns =
      assigns
      |> assign(:grid_class, grid_class)
      |> assign_new(:date_label, fn -> gettext("Date") end)
      |> assign_new(:time_label, fn -> gettext("Time") end)
      |> assign_new(:duration_label, fn -> gettext("Duration") end)
      |> assign_new(:timezone_label, fn -> gettext("Timezone") end)
      |> assign_new(:formatted_date, fn -> LocalizationHelpers.format_date(assigns.date) end)
      |> assign_new(:formatted_duration, fn ->
        LocalizationHelpers.format_duration(assigns.duration)
      end)
      |> assign_new(:formatted_timezone, fn -> Timezones.format(assigns.timezone) end)

    ~H"""
    <div class={@grid_class}>
      <div>
        <p class="booking-detail-label">{@date_label}</p>
        <p class="booking-detail-value">{@formatted_date}</p>
      </div>
      <div>
        <p class="booking-detail-label">{@time_label}</p>
        <p class="booking-detail-value">{@time}</p>
      </div>
      <div>
        <p class="booking-detail-label">{@duration_label}</p>
        <p class="booking-detail-value">{@formatted_duration}</p>
      </div>
      <div>
        <p class="booking-detail-label">{@timezone_label}</p>
        <p class="booking-detail-value">{@formatted_timezone}</p>
      </div>
    </div>
    """
  end

  # ========== PRIVATE HELPERS ==========

  defp render_answer(%{"type" => "yes_no"}, true), do: gettext("Yes")
  defp render_answer(%{"type" => "yes_no"}, _other), do: gettext("No")

  defp render_answer(%{"type" => "multi_select", "options" => opts}, values)
       when is_list(values) do
    Enum.map_join(
      Enum.filter(opts, &(&1["key"] in values)),
      ", ",
      & &1["label"]
    )
  end

  defp render_answer(%{"type" => "single_select", "options" => opts}, value) do
    case Enum.find(opts, &(&1["key"] == value)) do
      %{"label" => label} -> label
      _other -> to_string(value || "")
    end
  end

  defp render_answer(%{"type" => "note"}, %{"confirmed" => true, "confirmed_at" => at}) do
    gettext("✓ Acknowledged (%{at})", at: at)
  end

  defp render_answer(_d, nil), do: ""
  defp render_answer(_d, value), do: to_string(value)

  defp get_organizer_text(nil), do: ""

  defp get_organizer_text(organizer_profile) do
    case Profiles.display_name(organizer_profile) do
      nil -> ""
      name -> gettext("with %{name}", name: name)
    end
  end
end
