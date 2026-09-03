defmodule TymeslotWeb.Dashboard.MeetingSettings.Card do
  @moduledoc """
  Component for displaying meeting type cards with toggle and action buttons.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext
  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.MeetingTypes
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
          <Icons.icon name={@type.icon} class="w-5 h-5 text-tymeslot-600 shrink-0" />
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
              title={
                dgettext(
                  "dashboard_meeting_types",
                  "Hidden from your public booking page; reachable only by its direct link"
                )
              }
            >
              <Icons.icon name="hero-eye-slash-mini" class="w-3 h-3" />{dgettext(
                "dashboard_meeting_types",
                "Unlisted"
              )}
            </span>
          </div>
          <p
            :if={described?(@type)}
            class="mt-0.5 text-token-xs text-tymeslot-500 leading-relaxed line-clamp-2"
          >
            {@type.description}
          </p>
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
              {dgettext("dashboard_meeting_types", "%{minutes} min", minutes: @type.duration_minutes)}
            </span>
            <%= if paid?(@type) do %>
              <span class="flex items-center shrink-0 font-medium text-emerald-600">
                <Icons.icon name="hero-banknotes-mini" class="w-3.5 h-3.5 mr-1" />
                {format_amount(@type.price_cents, @currency)}
              </span>
            <% end %>
            <.location_summary type={@type} icon_size={@icon_size} />
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
            title={dgettext("dashboard_meeting_types", "Edit")}
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
            title={dgettext("dashboard_meeting_types", "Delete")}
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
            aria_label={
              dgettext("dashboard_meeting_types", "Toggle %{name} availability", name: @type.name)
            }
            class="shrink-0"
          />
        </div>
      </div>
    </div>
    """
  end

  defp paid?(%{payment_required: true, price_cents: cents}) when is_integer(cents), do: true
  defp paid?(_type), do: false

  defp described?(%{description: nil}), do: false
  defp described?(%{description: description}), do: String.trim(description) != ""

  # One location is named; several are counted. Naming them all would push
  # the calendar and question badges off the row on a card that is already a
  # single line of metadata.
  attr :type, :map, required: true
  attr :icon_size, :string, required: true

  defp location_summary(assigns) do
    assigns = assign(assigns, :locations, MeetingTypes.location_options(assigns.type))

    ~H"""
    <span :if={length(@locations) > 1} class="flex items-center shrink-0">
      <Icons.icon name="hero-map-pin-mini" class="w-3.5 h-3.5 mr-1 text-tymeslot-500" />
      <span>
        {dngettext(
          "dashboard_meeting_types",
          "%{count} location",
          "%{count} locations",
          length(@locations)
        )}
      </span>
    </span>
    <span :if={match?([_single], @locations)} class="flex items-center min-w-0">
      <span class="mr-1.5 shrink-0">
        <%!-- A video location keeps its provider's own mark, which is how the
              host recognises which account the rooms land on; the other kinds
              have no provider and take a plain glyph. --%>
        <ProviderIcon.provider_icon
          :if={video_provider(hd(@locations), @type)}
          provider={video_provider(hd(@locations), @type)}
          size={@icon_size}
        />
        <Icons.icon
          :if={is_nil(video_provider(hd(@locations), @type))}
          name={kind_icon(hd(@locations).kind)}
          class="w-3.5 h-3.5 text-tymeslot-500"
        />
      </span>
      <span class="truncate max-w-[10rem]">{hd(@locations).label}</span>
    </span>
    """
  end

  # The provider whose mark a video location shows, or nil for a location
  # that is not a video call (or whose integration has since been deleted,
  # leaving nothing to name).
  defp video_provider(%{kind: "video"}, %{video_integration: %{provider: provider}}), do: provider
  defp video_provider(_location, _type), do: nil

  defp kind_icon("video"), do: "hero-video-camera-mini"
  defp kind_icon("phone"), do: "hero-phone-mini"
  defp kind_icon("in_person"), do: "hero-building-office-mini"
  defp kind_icon(_kind), do: "hero-map-pin-mini"

  defp custom_question_count(%{custom_fields: fields}) when is_list(fields), do: length(fields)
  defp custom_question_count(_type), do: 0

  defp custom_questions_label(type) do
    count = custom_question_count(type)

    dngettext(
      "dashboard_meeting_types",
      "+%{count} custom question",
      "+%{count} custom questions",
      count,
      count: count
    )
  end

  defp calendar_display_name(%{calendar_integration: integration} = type) do
    calendar = Enum.find(integration.calendar_list || [], &(&1.id == type.target_calendar_id))

    name =
      if calendar do
        DisplayHelpers.extract_calendar_display_name(calendar)
      else
        dgettext("dashboard_meeting_types", "Calendar")
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
