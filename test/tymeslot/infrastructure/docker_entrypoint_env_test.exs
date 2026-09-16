defmodule Tymeslot.Infrastructure.DockerEntrypointEnvTest do
  @moduledoc """
  `start-docker.sh` exports a default for every variable it knows before the
  release boots, often an empty string. The release's `.env` reader leaves a
  key that is already set alone, so when the file was read by the release
  alone, a value set only in `/app/data/.env` never arrived: `SMTP_PASSWORD`
  came through empty and `EMAIL_ADAPTER` stayed `test`.

  The entrypoint now applies the file itself, before its defaults. This runs
  the script's own environment handling (the file load, the section-1
  defaults and the exports handed to the release) over a fixture, so moving
  the load back below the defaults fails here. Nothing else in the script
  runs: it would start PostgreSQL.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure

  @script Path.expand("../../../start-docker.sh", __DIR__)
  @reader Path.expand("../../../scripts/dotenv-reader.sh", __DIR__)

  @moduletag :tmp_dir

  test "a value set only in /app/data/.env reaches the release", %{tmp_dir: tmp_dir} do
    env = run(tmp_dir, "SMTP_PASSWORD=from_file\nEMAIL_ADAPTER=smtp\nPOSTGRES_PASSWORD=pg_file\n")

    assert env["SMTP_PASSWORD"] == "from_file"
    assert env["EMAIL_ADAPTER"] == "smtp"
    assert env["POSTGRES_PASSWORD"] == "pg_file"
  end

  test "a variable passed to the container still wins over the file", %{tmp_dir: tmp_dir} do
    env = run(tmp_dir, "SMTP_PASSWORD=from_file\n", [{"SMTP_PASSWORD", "from_docker"}])

    assert env["SMTP_PASSWORD"] == "from_docker"
  end

  test "defaults still apply to keys neither sets", %{tmp_dir: tmp_dir} do
    env = run(tmp_dir, "SMTP_PASSWORD=from_file\n")

    assert env["EMAIL_ADAPTER"] == "test"
    assert env["POSTGRES_PASSWORD"] == "tymeslot"
    assert env["SMTP_HOST"] == ""
  end

  # Builds a harness from the script's section 0 and section 1 and its export
  # lines, pointed at a fixture file instead of /app/data/.env.
  defp run(tmp_dir, contents, container_env \\ []) do
    env_file = Path.join(tmp_dir, ".env")
    File.write!(env_file, contents)

    script = File.read!(@script)

    [_shebang, from_section_0] =
      String.split(script, "# ==================== SECTION 0:", parts: 2)

    [sections_0_and_1, _rest] =
      String.split(from_section_0, "# ==================== SECTION 2:", parts: 2)

    load_line = ~S|. "$(dirname "$0")/dotenv-reader.sh"|
    assert sections_0_and_1 =~ "ENV_FILE=/app/data/.env"
    assert sections_0_and_1 =~ load_line

    head =
      ("#" <> sections_0_and_1)
      |> String.replace("ENV_FILE=/app/data/.env", "ENV_FILE=#{env_file}")
      |> String.replace(load_line, ". #{@reader}")

    exports =
      script
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "export "))

    assert Enum.any?(exports, &String.starts_with?(&1, "export SMTP_PASSWORD="))

    harness = Path.join(tmp_dir, "harness.sh")

    File.write!(harness, """
    set -eu
    # The script's own progress output is discarded; fd 3 carries the result.
    exec 3>&1 1>/dev/null
    #{head}
    #{Enum.join(exports, "\n")}
    for key in SMTP_PASSWORD SMTP_HOST EMAIL_ADAPTER POSTGRES_PASSWORD; do
      printf '%s\\0%s\\0' "$key" "${!key}" >&3
    done
    """)

    cleared = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)

    {output, 0} =
      System.cmd("/bin/bash", [harness], env: cleared ++ [{"LANG", "C.UTF-8"} | container_env])

    output
    |> :binary.split(<<0>>, [:global])
    |> Enum.chunk_every(2, 2, :discard)
    |> Map.new(fn [key, value] -> {key, value} end)
  end
end
