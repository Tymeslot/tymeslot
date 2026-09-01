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
  alias Tymeslot.Integrations.Providers.Families

  # One heading per family, in the vocabulary's own order. `nil` means the
  # group renders without a heading. The msgids are marked for extraction
  # here and translated at render time, so the label follows the viewer's
  # locale rather than the compiling machine's.
  @family_labels %{
    oauth: nil,
    caldav: dgettext_noop("dashboard_calendar_settings", "CalDAV servers"),
    ews: dgettext_noop("dashboard_calendar_settings", "Exchange servers"),
    subscription: dgettext_noop("dashboard_calendar_settings", "Calendar subscriptions"),
    other: dgettext_noop("dashboard_calendar_settings", "Other")
  }

  # This module used to enumerate the groups by hand, which silently dropped
  # any family it had not been told about: a new family reached the picker as
  # a provider that had simply vanished from the modal, with no error. Deriving
  # the groups from the vocabulary makes that impossible, and this check makes
  # the remaining half of the edit — deciding what the new group is called —
  # a build failure rather than a missing heading.
  @unlabelled_families Families.all() -- Map.keys(@family_labels)

  if @unlabelled_families != [] do
    raise "provider families #{inspect(@unlabelled_families)} have no picker group label; " <>
            "add one to @family_labels in TymeslotWeb.Dashboard.CalendarSettings.ProviderPicker"
  end

  @doc """
  Groups `available` descriptors for the picker modal, in the family order
  `Tymeslot.Integrations.Providers.Families.all/0` declares: OAuth providers
  (Google, Outlook) first, then CalDAV presets, then feed subscriptions — no
  nested reveal. Empty groups are dropped.

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

    Families.all()
    |> Enum.map(&%{label: label(&1), providers: Map.get(by_family, &1, [])})
    |> Enum.reject(&(&1.providers == []))
  end

  # Map.fetch! rather than Map.get: a family with no entry is the bug this
  # module is guarding against, and it should shout rather than render an
  # unlabelled group.
  defp label(family) do
    case Map.fetch!(@family_labels, family) do
      nil -> nil
      msgid -> Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_calendar_settings", msgid)
    end
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
