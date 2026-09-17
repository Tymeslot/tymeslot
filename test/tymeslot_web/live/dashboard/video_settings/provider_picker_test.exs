defmodule TymeslotWeb.Live.Dashboard.VideoSettings.ProviderPickerTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Providers.Descriptor
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias TymeslotWeb.Live.Dashboard.VideoSettings.ProviderPicker

  defp descriptor(type) do
    %Descriptor{
      domain: :video,
      type: type,
      display_name: ProviderConfig.display_name(type),
      config_schema: %{},
      provider_module: ProviderConfig.get_provider_module(type)
    }
  end

  defp all_descriptors do
    Enum.map([:google_meet, :teams, :zoom, :kmeet, :mirotalk, :jitsi, :custom], &descriptor/1)
  end

  describe "groups/2" do
    test "returns the three display groups in order" do
      assert [hosted, self_hosted, other] = ProviderPicker.groups(all_descriptors(), [])
      assert hosted.label =~ "Hosted"
      assert self_hosted.label =~ "Self-hosted"
      assert other.label =~ "Other"
    end

    test "files each provider in its group" do
      [hosted, self_hosted, other] = ProviderPicker.groups(all_descriptors(), [])

      assert providers(hosted) == ~w(google_meet teams zoom kmeet)
      assert providers(self_hosted) == ~w(mirotalk jitsi)
      assert providers(other) == ~w(custom)
    end

    test "every registered provider lands in exactly one group" do
      groups = ProviderPicker.groups(all_descriptors(), [])
      all = Enum.flat_map(groups, &providers/1)

      assert Enum.sort(all) == Enum.sort(~w(google_meet teams zoom kmeet mirotalk jitsi custom))
      assert Enum.uniq(all) == all
    end

    test "drops a group with no available providers" do
      groups = ProviderPicker.groups([descriptor(:custom)], [])
      assert [%{label: label}] = groups
      assert label =~ "Other"
    end

    test "marks a provider connected when the user holds an integration for it" do
      [hosted | _rest] = ProviderPicker.groups(all_descriptors(), [%{provider: "kmeet"}])
      kmeet = Enum.find(hosted.providers, &(&1.provider == "kmeet"))
      assert kmeet.connected?
    end

    test "dispatches every card through setup_provider" do
      groups = ProviderPicker.groups(all_descriptors(), [])

      for group <- groups, entry <- group.providers do
        assert entry.click_event == "setup_provider"
      end
    end
  end

  defp providers(group), do: Enum.map(group.providers, & &1.provider)
end
