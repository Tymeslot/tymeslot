defmodule TymeslotWeb.Dashboard.MeetingSettings.Card do
  @moduledoc """
  Component for displaying meeting type cards with toggle and action buttons.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext
  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Components.UI.StatusSwitch

  @doc """
  Renders a meeting type card with status toggle and action buttons.
  """
  attr :type, :map, required: true
  attr :myself, :any, required: true
  attr :currency, :string, default: "eur"
  attr :icon_size, :string, default: "mini", values: ["compact", "medium", "large", "mini"]

  @spec meeting_type_card(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_type_card(assigns) do
    ~H"""
    <div class={[
      "card-glass py-3 px-4",
      if(@type.is_active, do: "card-glass-available", else: "card-glass-unavailable")
    ]}>
      <div class="flex items-center gap-3">
        <%!-- Drag Handle --%>
        <div class="cursor-grab active:cursor-grabbing text-tymeslot-400 shrink-0">
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 8h16M4 16h16"
            />
          </svg>
        </div>

        <%= if @type.icon && @type.icon != "none" do %>
          <span class={[@type.icon, "w-5 h-5 text-tymeslot-600 shrink-0"]} />
        <% end %>

        <%!-- Name + details --%>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 min-w-0">
            <h3 class="text-token-base font-medium text-tymeslot-800 truncate">
              {@type.name}
            </h3>
            <span
              :if={@type.is_private}
              class="shrink-0 inline-flex items-center gap-1 px-2 py-0.5 rounded-token-full bg-tymeslot-100 text-tymeslot-600 text-token-xs font-medium"
              title={dgettext("dashboard", "Hidden from your public booking page; reachable only by its direct link")}
            >
              <Icons.icon name="hero-eye-slash-mini" class="w-3 h-3" />{dgettext("dashboard", "Unlisted")}
            </span>
          </div>
          <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5 mt-0.5 text-token-xs text-tymeslot-600">
            <span class="flex items-center shrink-0">
              <svg class="w-3.5 h-3.5 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              {@type.duration_minutes} min
            </span>
            <%= if paid?(@type) do %>
              <span class="flex items-center shrink-0 font-medium text-emerald-600">
                <Icons.icon name="hero-banknotes-mini" class="w-3.5 h-3.5 mr-1" />
                {format_amount(@type.price_cents, @currency)}
              </span>
            <% end %>
            <%= if @type.allow_video do %>
              <span class="flex items-center min-w-0">
                <%= if @type.video_integration do %>
                  <span class="mr-1.5 shrink-0">
                    <ProviderIcon.provider_icon
                      provider={@type.video_integration.provider}
                      size={@icon_size}
                    />
                  </span>
                  <span class="truncate max-w-[10rem]">
                    {@type.video_integration.name}
                  </span>
                <% else %>
                  <svg
                    class="w-3.5 h-3.5 mr-1 text-blue-400 shrink-0"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
                    />
                  </svg>
                  <span>Video</span>
                <% end %>
              </span>
            <% else %>
              <span class="flex items-center">
                <ProviderIcon.provider_icon provider="in_person" size={@icon_size} class="mr-1" />
                <span>In-person</span>
              </span>
            <% end %>
            <%= if @type.calendar_integration do %>
              <span class="flex items-center min-w-0">
                <span class="mr-1.5 shrink-0">
                  <ProviderIcon.provider_icon
                    provider={@type.calendar_integration.provider}
                    size={@icon_size}
                  />
                </span>
                <span class="truncate max-w-[8rem]">
                  {@type.calendar_integration.name}
                </span>
                <span class="ml-1 text-tymeslot-500 shrink-0">
                  ({calendar_display_name(@type)})
                </span>
              </span>
            <% end %>
            <%= if custom_question_count(@type) > 0 do %>
              <span class="flex items-center shrink-0 text-tymeslot-500">
                <Icons.icon name="hero-question-mark-circle-mini" class="w-3.5 h-3.5 mr-1" />
                {custom_questions_label(@type)}
              </span>
            <% end %>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="flex items-center gap-1.5 shrink-0">
          <button
            phx-click="edit_type"
            phx-value-id={@type.id}
            phx-target={@myself}
            class="p-1.5 text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 rounded-lg transition-colors"
            title="Edit"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
              />
            </svg>
          </button>

          <button
            phx-click="show_delete_modal"
            phx-value-id={@type.id}
            phx-target={@myself}
            class="p-1.5 text-red-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors"
            title="Delete"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
          </button>

          <StatusSwitch.status_switch
            id={"meeting-type-toggle-#{@type.id}"}
            checked={@type.is_active}
            size={:small}
            on_change="toggle_type"
            target={@myself}
            phx_value_id={to_string(@type.id)}
            aria_label={"Toggle #{@type.name} availability"}
            class="shrink-0"
          />
        </div>
      </div>
    </div>
    """
  end

  defp paid?(%{payment_required: true, price_cents: cents}) when is_integer(cents), do: true
  defp paid?(_type), do: false

  defp custom_question_count(%{custom_fields: fields}) when is_list(fields), do: length(fields)
  defp custom_question_count(_type), do: 0

  defp custom_questions_label(type) do
    case custom_question_count(type) do
      1 -> "+1 custom question"
      count -> "+#{count} custom questions"
    end
  end

  defp calendar_display_name(%{calendar_integration: integration} = type) do
    calendar =
      Enum.find(integration.calendar_list || [], fn cal ->
        (cal["id"] || cal[:id]) == type.target_calendar_id
      end)

    name =
      if calendar do
        DisplayHelpers.extract_calendar_display_name(calendar)
      else
        "Calendar"
      end

    truncate_calendar_name(name)
  end

  defp truncate_calendar_name(name) when is_binary(name) do
    max_length = 15
    ellipsis = "..."

    if String.length(name) > max_length do
      String.slice(name, 0, max_length - String.length(ellipsis)) <> ellipsis
    else
      name
    end
  end
end
