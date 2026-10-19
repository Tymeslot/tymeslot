defmodule Tymeslot.Integrations.Calendar.CreationProviderAllowlistTest do
  @moduledoc """
  The calendar connection form connects CalDAV-family servers only. A
  submission naming any other provider is refused by the context, whatever
  the form sent, before anything is probed, charged or stored.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Security.RateLimiter

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

  for provider <- ["google", "outlook", "ics_url", "debug", "not-a-provider"] do
    test "refuses #{provider}" do
      user = insert(:user)

      assert {:error, {:form_errors, %{generic: [message]}}} =
               Calendar.create_integration_with_validation(user.id, form(unquote(provider)))

      assert message =~ "Unsupported provider"
      assert Calendar.list_integrations(user.id) == []
    end
  end

  test "a refused provider costs nothing from the write budget" do
    user = insert(:user)

    {:error, {:form_errors, _errors}} =
      Calendar.create_integration_with_validation(user.id, form("google"))

    writes_left =
      fn -> RateLimiter.check(:integration_write, user.id) end
      |> Stream.repeatedly()
      |> Enum.take_while(&(&1 == :ok))
      |> length()

    assert writes_left == 30
  end
end
