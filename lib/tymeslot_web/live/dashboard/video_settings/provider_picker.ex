defmodule TymeslotWeb.Live.Dashboard.VideoSettings.ProviderPicker do
  @moduledoc """
  Shapes the video provider descriptors into the labelled groups the picker
  modal renders.

  The grouping is deliberately video's own rather than the shared provider
  family. A descriptor's `oauth` flag is derived from its family membership and
  routes the connect button, so regrouping Google Meet as "hosted" in the
  family table would break its OAuth flow. Here the two concerns stay separate:
  the family says how a provider connects, this table says where its card sits.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Providers.Descriptor
  alias Tymeslot.Integrations.Video.ProviderConfig

  @groups [:hosted, :self_hosted, :other]

  @group_labels %{
    hosted: dgettext_noop("dashboard_video", "Hosted services"),
    self_hosted: dgettext_noop("dashboard_video", "Self-hosted"),
    other: dgettext_noop("dashboard_video", "Other")
  }

  @provider_groups %{
    google_meet: :hosted,
    teams: :hosted,
    zoom: :hosted,
    kmeet: :hosted,
    mirotalk: :self_hosted,
    jitsi: :self_hosted,
    nextcloud_talk: :self_hosted,
    custom: :other
  }

  # Compile-time completeness, mirroring the calendar picker's label check: a
  # provider added to ProviderConfig without a group here, or a group without a
  # label, fails the build rather than silently vanishing from the picker.
  missing_group = ProviderConfig.all_providers_with_dev() -- Map.keys(@provider_groups)

  if missing_group != [] do
    raise "video providers without a picker group: #{inspect(missing_group)}"
  end

  missing_label = @groups -- Map.keys(@group_labels)

  if missing_label != [] do
    raise "picker groups without a label: #{inspect(missing_label)}"
  end

  @spec groups([Descriptor.t()], [map()]) :: [map()]
  def groups(available, integrations) do
    @groups
    |> Enum.map(fn group ->
      %{
        label: label(group),
        providers:
          available
          |> Enum.filter(&(Map.get(@provider_groups, &1.type) == group))
          |> Enum.map(&provider_entry(&1, integrations))
      }
    end)
    |> Enum.reject(&(&1.providers == []))
  end

  # Gettext.dgettext/2 rather than the `use Gettext` macro: the label is
  # looked up dynamically from `@group_labels`, and the macro form requires a
  # compile-time literal msgid. See the calendar picker's `label/1` for the
  # same pattern.
  defp label(group) do
    Gettext.dgettext(
      TymeslotWeb.Gettext,
      "dashboard_video",
      Map.fetch!(@group_labels, group)
    )
  end

  defp provider_entry(descriptor, integrations) do
    provider = Atom.to_string(descriptor.type)

    %{
      provider: provider,
      title: descriptor.display_name,
      description: descriptor.description,
      click_event: "setup_provider",
      connected?: Enum.any?(integrations, &(&1.provider == provider))
    }
  end
end
