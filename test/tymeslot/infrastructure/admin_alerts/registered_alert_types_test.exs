defmodule Tymeslot.Infrastructure.AdminAlerts.RegisteredAlertTypesTest do
  @moduledoc """
  Every alert type raised in Core's code is registered in `AlertTypes`. An
  unregistered one still sends, but as a generic "General" warning with no
  dedup rule, and the type spec no longer catches a mistyped name.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  @call ~r/AdminAlerts\.(?:report|send_alert)\(\s*:(\w+)/

  test "every alert type raised in lib/ is registered" do
    raised =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&Regex.scan(@call, File.read!(&1), capture: :all_but_first))
      |> Enum.map(fn [name] -> name end)
      |> Enum.uniq()

    registered = AlertTypes.registered_types() |> Map.keys() |> Enum.map(&Atom.to_string/1)

    assert raised != []
    assert raised -- registered == []
  end

  test "an unregistered type is logged as such" do
    log =
      capture_log(fn ->
        AdminAlerts.send_alert(:no_such_alert_type, %{summary: "test"})
      end)

    assert log =~ "not registered"
  end
end
