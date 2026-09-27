defmodule Tymeslot.Integrations.Calendar.CreationPrevalidationSkipTest do
  @moduledoc """
  A CalDAV-family provider the operator has switched off has no enabled
  provider to probe with, so creation goes ahead unprobed. That skip is
  logged rather than silent.
  """

  # async: false: the provider toggle is global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Test.LogCapture

  test "logs a warning with the provider and user when the probe is skipped" do
    providers = Application.get_env(:tymeslot, :calendar_providers)
    with_config(:tymeslot, calendar_providers: Map.put(providers, :zimbra, enabled: false))
    LogCapture.attach()

    attrs = %{
      provider: "zimbra",
      user_id: 42,
      base_url: "https://zimbra.example.com",
      username: "user",
      password: "pass"
    }

    assert Creation.prevalidate_config(attrs) == {:ok, attrs}

    event =
      LogCapture.await_log(
        "Skipped the connection probe for a calendar provider that is switched off"
      )

    assert event.level == :warning
    assert event.meta.provider == "zimbra"
    assert event.meta.user_id == 42
  end

  test "never logs a provider string outside the known CalDAV family" do
    LogCapture.attach()

    attrs = %{provider: String.duplicate("x", 10_000), user_id: 42}

    assert Creation.prevalidate_config(attrs) == {:ok, attrs}
    refute_receive {:captured_log, %{meta: %{provider: _provider}}}
  end
end
