defmodule TymeslotWeb.Dashboard.CalendarSettings.ProviderPickerTest do
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :components

  alias Tymeslot.Integrations.Providers.Descriptor
  alias Tymeslot.Integrations.Providers.Directory
  alias Tymeslot.Integrations.Providers.Families
  alias TymeslotWeb.Dashboard.CalendarSettings.ProviderPicker

  defp descriptor(family) do
    %Descriptor{
      domain: :calendar,
      type: :caldav,
      display_name: "Provider for #{family}",
      description: "Connects somehow",
      oauth: family == :oauth,
      family: family,
      config_schema: %{},
      provider_module: nil
    }
  end

  describe "groups/2" do
    test "renders a group for every family in the vocabulary, in vocabulary order" do
      # The picker used to enumerate its groups by hand, so a family it had not
      # been told about silently vanished from the modal. Feeding it one
      # provider per family proves each one still comes out the other side.
      groups = ProviderPicker.groups(Enum.map(Families.all(), &descriptor/1), [])

      assert length(groups) == length(Families.all())

      assert Enum.flat_map(groups, fn group -> Enum.map(group.providers, & &1.title) end) ==
               Enum.map(Families.all(), &"Provider for #{&1}")
    end

    test "every family resolves to a heading, and only the OAuth group has none" do
      # Building this map calls the label lookup once per family, which is what
      # would blow up if a family were added without deciding what its group is
      # called.
      labels =
        Map.new(Families.all(), fn family ->
          [group] = ProviderPicker.groups([descriptor(family)], [])
          {family, group.label}
        end)

      unlabelled = for {family, nil} <- labels, do: family
      assert unlabelled == [:oauth]

      blank =
        labels
        |> Map.drop([:oauth])
        |> Enum.reject(fn {_family, label} -> is_binary(label) and label != "" end)

      assert blank == []
    end

    test "drops families with no available providers" do
      groups = ProviderPicker.groups([descriptor(:oauth)], [])

      assert [%{label: nil, providers: [%{title: "Provider for oauth"}]}] = groups
    end

    test "names the CalDAV, subscription and other groups" do
      labels =
        [:caldav, :subscription, :other]
        |> Enum.map(&descriptor/1)
        |> ProviderPicker.groups([])
        |> Enum.map(& &1.label)

      assert labels == ["CalDAV servers", "Calendar subscriptions", "Other"]
    end

    test "marks providers the user has already connected" do
      groups = ProviderPicker.groups([descriptor(:caldav)], [%{provider: "caldav"}])

      assert [%{providers: [%{provider: "caldav", connected?: true}]}] = groups
    end

    test "groups the real calendar directory into OAuth, CalDAV, Exchange then subscriptions" do
      groups = ProviderPicker.groups(Directory.list(:calendar), [])

      assert Enum.map(groups, & &1.label) == [
               nil,
               "CalDAV servers",
               "Exchange servers",
               "Calendar subscriptions"
             ]

      [oauth_group, caldav_group, ews_group, subscription_group] = groups

      assert Enum.map(oauth_group.providers, & &1.provider) == ["google", "outlook"]
      assert "caldav" in Enum.map(caldav_group.providers, & &1.provider)
      assert Enum.map(ews_group.providers, & &1.provider) == ["exchange"]
      assert Enum.map(subscription_group.providers, & &1.provider) == ["ics_url"]
    end
  end
end
