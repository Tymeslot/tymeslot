defmodule Tymeslot.Infrastructure.DockerEntrypointEnvTest do
  @moduledoc """
  `start-docker.sh` exports a default for every variable it knows before the
  release boots, often an empty string. The release's `.env` reader leaves a
  key that is already set alone, so when the file was read by the release
  alone, a value set only in `/app/data/.env` never arrived: `SMTP_PASSWORD`
  came through empty and `EMAIL_ADAPTER` stayed `test`.

  The entrypoint now applies the file itself, before its defaults, with one
  exception: the keys that choose the database and the embedded cluster's
  role stay with the container environment, because earlier releases never
  read them from the file and an install may carry a stale copy there.

  This runs the script's own environment handling (the file load, the
  section-1 defaults and the exports handed to the release) over a fixture,
  so moving the load back below the defaults, or letting the file choose the
  database, fails here. Nothing else in the script runs: it would start
  PostgreSQL.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure

  @script Path.expand("../../../start-docker.sh", __DIR__)
  @reader Path.expand("../../../scripts/dotenv-reader.sh", __DIR__)

  @moduletag :tmp_dir

  test "a value set only in /app/data/.env reaches the release", %{tmp_dir: tmp_dir} do
    {env, _output} =
      run(tmp_dir, "SMTP_PASSWORD=from_file\nEMAIL_ADAPTER=smtp\nPOSTGRES_PASSWORD=pg_file\n")

    assert env["SMTP_PASSWORD"] == "from_file"
    assert env["EMAIL_ADAPTER"] == "smtp"
    assert env["POSTGRES_PASSWORD"] == "pg_file"
  end

  test "a variable passed to the container still wins over the file", %{tmp_dir: tmp_dir} do
    {env, _output} = run(tmp_dir, "SMTP_PASSWORD=from_file\n", [{"SMTP_PASSWORD", "from_docker"}])

    assert env["SMTP_PASSWORD"] == "from_docker"
  end

  test "defaults still apply to keys neither sets", %{tmp_dir: tmp_dir} do
    {env, _output} = run(tmp_dir, "SMTP_PASSWORD=from_file\n")

    assert env["EMAIL_ADAPTER"] == "test"
    assert env["POSTGRES_PASSWORD"] == "tymeslot"
    assert env["SMTP_HOST"] == ""
  end

  describe "database selection stays with the container" do
    test "POSTGRES_DB and DATABASE_URL in the file are ignored with a warning naming them",
         %{tmp_dir: tmp_dir} do
      {env, output} =
        run(
          tmp_dir,
          "POSTGRES_DB=stale_db\nDATABASE_URL=postgres://u:p@db.example.com/stale\nSMTP_PASSWORD=from_file\n"
        )

      assert env["POSTGRES_DB"] == "tymeslot"
      assert env["DATABASE_URL"] == ""
      assert env["SMTP_PASSWORD"] == "from_file"

      # The fixture's path holds the test name, so the key lists are matched
      # after the ".env:" separator rather than anywhere on the line.
      assert output =~ "container settings"
      assert keys_listed(output, "Ignored in") == "POSTGRES_DB DATABASE_URL"
      assert keys_listed(output, "Loaded from") == "SMTP_PASSWORD"
    end

    test "a POSTGRES_DB passed to the container is kept", %{tmp_dir: tmp_dir} do
      {env, output} = run(tmp_dir, "POSTGRES_DB=stale_db\n", [{"POSTGRES_DB", "from_docker"}])

      assert env["POSTGRES_DB"] == "from_docker"
      refute output =~ "Ignored in"
    end

    test "a file setting none of the container-only keys draws no warning", %{tmp_dir: tmp_dir} do
      {_env, output} = run(tmp_dir, "SMTP_PASSWORD=from_file\n")

      refute output =~ "Ignored in"
    end
  end

  describe "embedded cluster password" do
    test "an existing role is altered to the configured password" do
      section_6 = section(File.read!(@script), "SECTION 6:", "SECTION 7:")

      assert section_6 =~ "CREATE USER ${POSTGRES_USER} WITH PASSWORD ${PG_PASSWORD_LITERAL}"
      assert section_6 =~ "ALTER USER ${POSTGRES_USER} WITH PASSWORD ${PG_PASSWORD_LITERAL}"
    end

    test "a single quote in the password cannot end the SQL literal" do
      section_6 = section(File.read!(@script), "SECTION 6:", "SECTION 7:")

      [literal_line] =
        for line <- String.split(section_6, "\n"),
            String.starts_with?(String.trim_leading(line), "PG_PASSWORD_LITERAL="),
            do: line

      {literal, 0} =
        System.cmd(
          "/bin/bash",
          ["-c", "#{literal_line}\nprintf '%s' \"$PG_PASSWORD_LITERAL\""],
          env: [{"POSTGRES_PASSWORD", "it's o'clock"}]
        )

      assert literal == "'it''s o''clock'"
    end
  end

  defp keys_listed(output, prefix) do
    [line] = for line <- String.split(output, "\n"), line =~ prefix, do: line
    [_path, keys] = String.split(line, ".env:", parts: 2)
    String.trim(keys)
  end

  defp section(script, from, to) do
    [_before, from_marker] = String.split(script, "# ==================== #{from}", parts: 2)
    [section, _rest] = String.split(from_marker, "# ==================== #{to}", parts: 2)
    section
  end

  # Builds a harness from the script's section 0 and section 1 and its export
  # lines, pointed at a fixture file instead of /app/data/.env. Returns the
  # environment handed to the release and what the script printed on the way.
  defp run(tmp_dir, contents, container_env \\ []) do
    env_file = Path.join(tmp_dir, ".env")
    File.write!(env_file, contents)

    script = File.read!(@script)
    sections_0_and_1 = section(script, "SECTION 0:", "SECTION 2:")

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
    output_file = Path.join(tmp_dir, "output.log")

    File.write!(harness, """
    set -eu
    # The script's own progress output goes to a file; fd 3 carries the result.
    exec 3>&1 1>"#{output_file}"
    #{head}
    #{Enum.join(exports, "\n")}
    for key in SMTP_PASSWORD SMTP_HOST EMAIL_ADAPTER POSTGRES_PASSWORD POSTGRES_DB DATABASE_URL; do
      printf '%s\\0%s\\0' "$key" "${!key}" >&3
    done
    """)

    cleared = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)

    {result, 0} =
      System.cmd("/bin/bash", [harness], env: cleared ++ [{"LANG", "C.UTF-8"} | container_env])

    env =
      result
      |> :binary.split(<<0>>, [:global])
      |> Enum.chunk_every(2, 2, :discard)
      |> Map.new(fn [key, value] -> {key, value} end)

    {env, File.read!(output_file)}
  end
end
