defmodule Tymeslot.Integrations.Calendar.CreationPrevalidationSkipTest do
  @moduledoc """
  A CalDAV-family provider the operator has switched off is not in the
  registry, so its connection probe cannot run and creation goes ahead
  unprobed. That skip is logged rather than silent.
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

    event = LogCapture.await_log("Skipped the connection probe")
    assert event.level == :warning
    assert event.meta.provider == "zimbra"
    assert event.meta.user_id == 42
  end
end
