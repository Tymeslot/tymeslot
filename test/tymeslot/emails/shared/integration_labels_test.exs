defmodule Tymeslot.Emails.Shared.IntegrationLabelsTest do
  use ExUnit.Case, async: true

  @moduletag :emails
  @moduletag :integrations

  alias Tymeslot.Emails.Shared.IntegrationLabels

  alias Tymeslot.Emails.Templates.{
    IntegrationPaused,
    IntegrationReauthRequired,
    IntegrationUnhealthy
  }

  @user %{id: 1, name: "Alice", email: "alice@example.com"}

  describe "provider_name/2" do
    test "uses the registries' display names" do
      assert IntegrationLabels.provider_name(%{provider: "nextcloud_talk"}, :video) ==
               "Nextcloud Talk"

      assert IntegrationLabels.provider_name(%{provider: :mirotalk}, :video) == "MiroTalk P2P"
      assert IntegrationLabels.provider_name(%{provider: :google}, :calendar) == "Google Calendar"
      assert IntegrationLabels.provider_name(%{provider: "nextcloud"}, :calendar) == "Nextcloud"

      assert IntegrationLabels.provider_name(%{provider: :ics_url}, :calendar) ==
               "Calendar subscription"
    end

    test "humanises a provider the registry does not know" do
      assert IntegrationLabels.provider_name(%{provider: :custom_service}, :video) ==
               "Custom service"

      assert IntegrationLabels.provider_name(%{provider: "acme_cal"}, :calendar) == "Acme cal"
      assert IntegrationLabels.provider_name(%{provider: :acme}, :other) == "Acme"
    end
  end

  describe "integration_name/2" do
    test "adds the kind to a name that does not say it" do
      assert IntegrationLabels.integration_name(%{provider: :zoom}, :video) == "Zoom video"

      assert IntegrationLabels.integration_name(%{provider: :nextcloud}, :calendar) ==
               "Nextcloud calendar"
    end

    test "leaves a name that already says its kind alone" do
      assert IntegrationLabels.integration_name(%{provider: :google}, :calendar) ==
               "Google Calendar"

      assert IntegrationLabels.integration_name(%{provider: :ics_url}, :calendar) ==
               "Calendar subscription"

      assert IntegrationLabels.integration_name(%{provider: :custom}, :video) ==
               "Custom Video Link"
    end
  end

  describe "in another language" do
    test "translates the words around a brand name, never the brand" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert IntegrationLabels.integration_name(%{provider: :zoom}, :video) == "Zoom-Video"

        assert IntegrationLabels.integration_name(%{provider: :google}, :calendar) ==
                 "Google Calendar"

        assert IntegrationLabels.provider_name(%{provider: :ics_url}, :calendar) ==
                 "Kalenderabonnement"
      end)
    end
  end

  describe "settings_url/1" do
    test "points at the integrations page's tab for the kind" do
      assert IntegrationLabels.settings_url(:calendar) =~ "/dashboard/integrations?tab=calendars"
      assert IntegrationLabels.settings_url(:video) =~ "/dashboard/integrations?tab=video"
      assert IntegrationLabels.settings_url(:other) =~ ~r{/dashboard/integrations$}
    end
  end

  describe "the integration emails" do
    # Each email used to build its own label: paused and unhealthy said
    # "Mirotalk" and "Google", reconnect said "MiroTalk P2P".
    for {provider, kind, name, humanised} <- [
          {:mirotalk, :video, "MiroTalk P2P video", "Mirotalk"},
          {:google, :calendar, "Google Calendar", "Google calendar"}
        ] do
      test "all name #{provider} as #{name}" do
        integration = %{provider: unquote(provider), sync_error: nil}

        bodies =
          Enum.flat_map(
            [
              IntegrationPaused.render(@user, integration, unquote(kind), 14),
              IntegrationUnhealthy.render(@user, integration, unquote(kind)),
              IntegrationReauthRequired.render(@user, integration, unquote(kind))
            ],
            &[&1.html_body, &1.text_body]
          )

        assert Enum.reject(bodies, &(&1 =~ unquote(name))) == []
        assert Enum.filter(bodies, &(&1 =~ unquote(humanised))) == []
      end
    end
  end
end
