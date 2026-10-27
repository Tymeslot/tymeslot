defmodule Tymeslot.Integrations.Calendar.CreationPrevalidationSkipTest do
  @moduledoc """
  A CalDAV-family provider the operator has switched off has no enabled
  provider to probe with, so a calendar for it is refused rather than
  created unprobed.
  """

  # async: false: the provider toggle is global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.ConfigTestHelpers

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Test.LogCapture

  test "refuses a provider that is switched off instead of skipping the probe" do
    providers = Application.get_env(:tymeslot, :calendar_providers)
    with_config(:tymeslot, calendar_providers: Map.put(providers, :zimbra, enabled: false))

    attrs = %{
      provider: "zimbra",
      user_id: 42,
      base_url: "https://zimbra.example.com",
      username: "user",
      password: "pass"
    }

    assert {:error, %{discovery: message}} = Creation.prevalidate_config(attrs)
    assert message =~ "Unsupported provider"
  end

  test "refuses a calendar for a switched-off provider from the connection form" do
    providers = Application.get_env(:tymeslot, :calendar_providers)
    with_config(:tymeslot, calendar_providers: Map.put(providers, :zimbra, enabled: false))
    user = insert(:user)

    assert {:error, {:form_errors, %{generic: [_message]}}} =
             Calendar.create_integration_with_validation(user.id, form("zimbra"))

    assert Calendar.list_integrations(user.id) == []
  end

  test "never logs a provider string outside the known CalDAV family" do
    LogCapture.attach()

    attrs = %{provider: String.duplicate("x", 10_000), user_id: 42}

    assert Creation.prevalidate_config(attrs) == {:ok, attrs}
    refute_receive {:captured_log, %{meta: %{provider: _provider}}}
  end

  defp form(provider) do
    %{
      "name" => "Work",
      "provider" => provider,
      "url" => "https://dav.example.com/dav/",
      "username" => "alice",
      "password" => "secret",
      "calendar_paths" => ""
    }
  end
end
