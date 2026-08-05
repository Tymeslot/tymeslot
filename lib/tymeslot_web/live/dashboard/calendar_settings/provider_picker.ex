defmodule TymeslotWeb.Dashboard.CalendarSettings.ProviderPicker do
  @moduledoc """
  Builds the grouped provider list the calendar settings picker modal renders.

  Split out of `TymeslotWeb.Dashboard.CalendarSettingsComponent` so the
  component keeps to socket state and event handling: turning provider
  descriptors into display rows is presentation shaping, and it is the only
  part of that component with an opinion about how providers are categorised.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @doc """
  Groups `available` descriptors for the picker modal: OAuth providers
  (Google, Outlook) first, then CalDAV presets, then feed subscriptions —
  no nested reveal. Empty groups are dropped.

  Grouping is by the descriptor's family rather than by its `oauth` boolean:
  a subscribed feed speaks no CalDAV, so listing it under "CalDAV servers"
  would describe it as something it isn't.
  """
  @spec groups([map()], [map()]) :: [%{label: String.t() | nil, providers: [map()]}]
  def groups(available, integrations) do
    by_family =
      available
      |> Enum.map(&provider_entry(&1, integrations))
      |> Enum.group_by(& &1.family)

    Enum.reject(
      [
        %{label: nil, providers: Map.get(by_family, :oauth, [])},
        %{
          label: dgettext("dashboard_calendar_settings", "CalDAV servers"),
          providers: Map.get(by_family, :caldav, [])
        },
        %{
          label: dgettext("dashboard_calendar_settings", "Calendar subscriptions"),
          providers: Map.get(by_family, :subscription, [])
        },
        %{
          label: dgettext("dashboard_calendar_settings", "Other"),
          providers: Map.get(by_family, :other, [])
        }
      ],
      &(&1.providers == [])
    )
  end

  defp provider_entry(descriptor, integrations) do
    provider = Atom.to_string(descriptor.type)

    %{
      provider: provider,
      title: descriptor.display_name,
      description: descriptor.description,
      click_event: ProviderConfig.click_event(descriptor.type),
      connected?: Enum.any?(integrations, &(&1.provider == provider)),
      oauth?: descriptor.oauth,
      family: descriptor.family
    }
  end
end
