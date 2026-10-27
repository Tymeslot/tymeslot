defmodule Tymeslot.Infrastructure.DockerStartDataKeyWarningTest do
  @moduledoc """
  `start-docker.sh` warns at boot when no data encryption key is configured.
  After a key rotation retires key 1, `DATA_ENCRYPTION_KEYS` alone is set, and
  that must count as configured, as it does in `config/runtime.exs`.

  This runs the script's own key check over a cleared environment. Nothing else
  in the script runs: it would start PostgreSQL.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :security
  @moduletag :tmp_dir

  @script Path.expand("../../../start-docker.sh", __DIR__)

  test "warns when neither variable is set", %{tmp_dir: tmp_dir} do
    assert run(tmp_dir, []) =~ "DATA_ENCRYPTION_KEY is not set"
  end

  test "warns when DATA_ENCRYPTION_KEY is blank", %{tmp_dir: tmp_dir} do
    assert run(tmp_dir, [{"DATA_ENCRYPTION_KEY", ""}]) =~ "DATA_ENCRYPTION_KEY is not set"
  end

  test "warns when the variables hold only whitespace", %{tmp_dir: tmp_dir} do
    output = run(tmp_dir, [{"DATA_ENCRYPTION_KEY", "  "}, {"DATA_ENCRYPTION_KEYS", " \t"}])

    assert output =~ "DATA_ENCRYPTION_KEY is not set"
  end

  test "is satisfied by DATA_ENCRYPTION_KEYS alone, as after key 1 is retired",
       %{tmp_dir: tmp_dir} do
    output = run(tmp_dir, [{"DATA_ENCRYPTION_KEYS", "2:key"}])

    refute output =~ "not set"
    assert output =~ "Data encryption key set"
  end

  test "is satisfied by DATA_ENCRYPTION_KEY", %{tmp_dir: tmp_dir} do
    output = run(tmp_dir, [{"DATA_ENCRYPTION_KEY", "key"}])

    refute output =~ "not set"
    assert output =~ "Data encryption key set"
  end

  defp run(tmp_dir, container_env) do
    [_before, rest] =
      String.split(File.read!(@script), "# DATA_ENCRYPTION_KEY is recommended", parts: 2)

    [check, _after] = String.split(rest, "# End of data encryption key check", parts: 2)
    harness = Path.join(tmp_dir, "harness.sh")
    File.write!(harness, "set -eu\n#" <> check)

    cleared = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)
    path = {"PATH", System.get_env("PATH")}

    {output, 0} = System.cmd("/bin/bash", [harness], env: cleared ++ [path | container_env])
    output
  end
end
