defmodule TymeslotWeb.Dashboard.CalendarSettings.AvailableProviders do
  @moduledoc """
  Renders the "Available Providers" grid for calendar settings.

  OAuth providers (Google, Outlook) each show as a card. CalDAV presets are
  collapsed: Apple iCloud and Nextcloud show up-front as first-class cards,
  while the remaining CalDAV presets stay folded behind an "Other CalDAV
  server" affordance until the reveal is toggled — avoiding a wall of
  near-identical CalDAV cards.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.ProviderCard
  alias TymeslotWeb.Dashboard.CalendarSettings.Helpers

  # The two CalDAV presets shown up-front. The folded set is everything else
  # CalDAV, derived from the central list so a new provider surfaces
  # automatically instead of drifting out of a hand-maintained literal.
  @caldav_always_types [:apple, :nextcloud]
  @caldav_folded_types ProviderConfig.caldav_based_providers() -- @caldav_always_types

  attr :available_calendar_providers, :list, required: true
  attr :integrations, :list, default: []
  attr :show_all_caldav, :boolean, default: false
  attr :myself, :any, required: true

  @spec available_providers_section(map()) :: Phoenix.LiveView.Rendered.t()
  def available_providers_section(assigns) do
    {caldav_providers, other_providers} =
      Enum.split_with(assigns.available_calendar_providers, fn descp ->
        ProviderConfig.caldav_based?(descp.type)
      end)

    {always_caldav, folded_caldav} = partition_caldav(caldav_providers)

    assigns =
      assigns
      |> assign(:caldav_providers, caldav_providers)
      |> assign(:other_providers, other_providers)
      |> assign(:always_caldav, always_caldav)
      |> assign(:folded_caldav, folded_caldav)
      |> assign(:folded_caldav_subtitle, folded_caldav_subtitle(folded_caldav))

    ~H"""
    <div class="space-y-8 mt-12">
      <div class="max-w-4xl">
        <.section_header level={2} title="Available Providers" />
        <p class="text-tymeslot-500 font-medium text-token-lg ml-1">
          Connect your favorite calendar service to sync availability and automate your scheduling workflow.
        </p>
      </div>

      <div class="space-y-10">
        <div :if={@other_providers != []} class="space-y-5">
          <h3 class="text-token-xl font-black text-tymeslot-800 tracking-tight">
            OAuth Providers
          </h3>
          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
            <.calendar_provider_card
              :for={descp <- @other_providers}
              descp={descp}
              integrations={@integrations}
              myself={@myself}
            />
          </div>
        </div>

        <div :if={@caldav_providers != []} class="space-y-5">
          <h3 class="text-token-xl font-black text-tymeslot-800 tracking-tight">
            CalDAV Servers
          </h3>
          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
            <.calendar_provider_card
              :for={descp <- @always_caldav}
              descp={descp}
              integrations={@integrations}
              myself={@myself}
            />
            <.calendar_provider_card
              :for={descp <- @folded_caldav}
              :if={@show_all_caldav}
              descp={descp}
              integrations={@integrations}
              myself={@myself}
            />
            <.other_caldav_card
              :if={@folded_caldav != []}
              expanded={@show_all_caldav}
              subtitle={@folded_caldav_subtitle}
              myself={@myself}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :expanded, :boolean, required: true
  attr :subtitle, :string, required: true
  attr :myself, :any, required: true

  defp other_caldav_card(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_caldav_options"
      phx-target={@myself}
      aria-expanded={to_string(@expanded)}
      class={[
        "card-glass transition-all duration-200 cursor-pointer hover:scale-[1.02]",
        "p-6 border-2 hover:border-teal-400/50 flex flex-col h-full text-left"
      ]}
    >
      <div class="flex items-start gap-4 mb-4 flex-1">
        <div class="flex items-center justify-center w-12 h-12 shrink-0 rounded-token-xl bg-tymeslot-50 text-tymeslot-500">
          <.icon
            name={if @expanded, do: "hero-chevron-up", else: "hero-server-stack"}
            class="w-6 h-6"
          />
        </div>
        <div class="flex-1">
          <h3 class="text-lg font-semibold text-tymeslot-800 mb-1">
            {if @expanded, do: "Show fewer", else: "Other CalDAV server"}
          </h3>
          <p class="text-sm text-tymeslot-600">
            {if @expanded, do: "Hide the additional CalDAV presets.", else: @subtitle}
          </p>
        </div>
      </div>
      <div class="btn btn-secondary w-full">
        {if @expanded, do: "Show fewer", else: "More options"}
      </div>
    </button>
    """
  end

  attr :descp, :map, required: true
  attr :integrations, :list, required: true
  attr :myself, :any, required: true

  defp calendar_provider_card(assigns) do
    info = Helpers.provider_card_info(assigns.descp.type)
    has_existing = Enum.any?(assigns.integrations, &(&1.provider == info.provider))

    assigns =
      assigns
      |> assign(:info, info)
      |> assign(:has_existing, has_existing)

    ~H"""
    <ProviderCard.provider_card
      provider={@info.provider}
      title={@descp.display_name}
      description={@info.desc}
      button_text={if @has_existing, do: "Add Another Account", else: @info.btn}
      click_event={@info.click}
      target={@myself}
      provider_value={@info.provider}
    />
    """
  end

  # --- Helpers ---

  # Splits CalDAV descriptors into the always-shown presets and the folded
  # rest, each ordered explicitly rather than by incoming order.
  defp partition_caldav(caldav_providers) do
    by_type = Map.new(caldav_providers, &{&1.type, &1})

    {order_by_types(by_type, @caldav_always_types), order_by_types(by_type, @caldav_folded_types)}
  end

  defp order_by_types(by_type, types) do
    Enum.flat_map(types, &List.wrap(Map.get(by_type, &1)))
  end

  # Subtitle for the "Other CalDAV server" card: names the branded folded
  # presets (generic CalDAV is covered by "any other CalDAV server").
  defp folded_caldav_subtitle(folded_caldav) do
    branded =
      folded_caldav
      |> Enum.reject(&(&1.type == :caldav))
      |> Enum.map(& &1.display_name)

    case format_name_list(branded) do
      "" -> "Connect any other CalDAV server."
      names -> "Connect #{names}, or any other CalDAV server."
    end
  end

  defp format_name_list([]), do: ""
  defp format_name_list([name]), do: name
  defp format_name_list([a, b]), do: "#{a} and #{b}"

  defp format_name_list(names) do
    {leading, [last]} = Enum.split(names, -1)
    "#{Enum.join(leading, ", ")}, and #{last}"
  end
end
