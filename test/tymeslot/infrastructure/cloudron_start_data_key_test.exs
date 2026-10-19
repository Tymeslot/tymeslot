defmodule Tymeslot.Infrastructure.CloudronStartDataKeyTest do
  @moduledoc """
  The Cloudron `start.sh` generates `DATA_ENCRYPTION_KEY` (key 1) on first run
  and exports it on every boot. Key rotation needs one exception: once
  `DATA_ENCRYPTION_KEYS` is set, a key file the operator deleted to retire key 1
  must not come back as a freshly generated key.

  This runs the script's own `DATA_ENCRYPTION_KEY` block over a temporary data
  directory. Nothing else in the script runs: it would chown `/app/data` and
  start the release.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :security
  @moduletag :tmp_dir

  @script Path.expand("../../../start.sh", __DIR__)

  test "first run generates key 1 and exports it", %{tmp_dir: tmp_dir} do
    {env, files} = run(tmp_dir, [])

    assert byte_size(env["DATA_ENCRYPTION_KEY"]) == 64
    assert files.key == env["DATA_ENCRYPTION_KEY"]
    assert files.env_file =~ "DATA_ENCRYPTION_KEY=#{env["DATA_ENCRYPTION_KEY"]}"
  end

  test "a later boot exports the generated key", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "data_encryption_key"), "generated-earlier")

    {env, _files} = run(tmp_dir, [])

    assert env["DATA_ENCRYPTION_KEY"] == "generated-earlier"
  end

  test "with DATA_ENCRYPTION_KEYS set, the generated key is still exported as key 1",
       %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "data_encryption_key"), "generated-earlier")

    {env, _files} = run(tmp_dir, [{"DATA_ENCRYPTION_KEYS", "2:new"}])

    assert env["DATA_ENCRYPTION_KEY"] == "generated-earlier"
  end

  test "with DATA_ENCRYPTION_KEYS set, a deleted key file is not regenerated",
       %{tmp_dir: tmp_dir} do
    {env, files} = run(tmp_dir, [{"DATA_ENCRYPTION_KEYS", "2:new"}])

    assert env["DATA_ENCRYPTION_KEY"] == ""
    assert files.key == nil
    refute files.env_file =~ "DATA_ENCRYPTION_KEY="
  end

  defp run(tmp_dir, container_env) do
    key_file = Path.join(tmp_dir, "data_encryption_key")
    env_file = Path.join(tmp_dir, ".env")

    block =
      @script
      |> File.read!()
      |> section("# Generate DATA_ENCRYPTION_KEY on first run", "# Create necessary directories")
      |> String.replace(
        ~S|DATA_KEY_FILE="/app/data/data_encryption_key"|,
        ~s|DATA_KEY_FILE="#{key_file}"|
      )

    harness = Path.join(tmp_dir, "harness.sh")

    File.write!(harness, """
    set -eu
    exec 3>&1 1>/dev/null
    ENV_FILE="#{env_file}"
    warn_if_overrides_generated() { :; }
    #{block}
    printf '%s' "${DATA_ENCRYPTION_KEY:-}" >&3
    """)

    cleared = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)
    path = {"PATH", System.get_env("PATH")}

    {exported, 0} = System.cmd("/bin/bash", [harness], env: cleared ++ [path | container_env])

    {%{"DATA_ENCRYPTION_KEY" => exported},
     %{key: read_optional(key_file), env_file: read_optional(env_file) || ""}}
  end

  defp read_optional(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> nil
    end
  end

  defp section(script, from, to) do
    [_before, rest] = String.split(script, from, parts: 2)
    [body, _after] = String.split(rest, to, parts: 2)
    from <> body
  end
end
